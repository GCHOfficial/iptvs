import 'dart:math';

import 'demo_source.dart';
import 'm3u_source.dart';
import 'source.dart';
import 'stalker_source.dart';
import 'xtream_source.dart';

enum SourceKind { stalker, xtream, m3u, demo }

final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Whether [s] looks like a canonical UUID. Cloud `sources.id` is a Postgres
/// `uuid`; locally-minted ids must match this shape to round-trip via push.
bool isUuid(String s) => _uuidRe.hasMatch(s);

/// A fresh random (v4) UUID for a newly created source, so the same id is usable
/// locally and in the cloud `sources` table. Uses [Random.secure].
String newSourceId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
  final hex = b.map((n) => n.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A saved, serializable provider configuration. [build] turns it into a live
/// [Source]. Stored (including credentials) via the SourceStore.
class SourceConfig {
  final String id;
  final SourceKind kind;
  final String label;
  final Map<String, String> fields;

  /// Per-source user preferences (not credentials) — e.g. hidden categories.
  /// Kept separate from [fields] so [build] never sees them and they can ride
  /// the source row into the cloud as a single `settings` blob. Free-form so new
  /// preferences don't require schema changes.
  final Map<String, dynamic> settings;

  const SourceConfig({
    required this.id,
    required this.kind,
    required this.label,
    required this.fields,
    this.settings = const {},
  });

  Source build() {
    // The user-assigned label is the canonical display name everywhere it's shown
    // (app bar, player badge, logs); fall back to each source's derived name when
    // it's blank.
    final name = label.trim().isEmpty ? null : label.trim();
    final catchupTimezone = settings['catchupTimezone']?.toString();
    final catchupOffsetMinutes = int.tryParse(
      '${settings['catchupOffsetMinutes'] ?? ''}',
    );
    final catchupMaxDays = int.tryParse('${settings['catchupMaxDays'] ?? ''}');
    switch (kind) {
      case SourceKind.stalker:
        return StalkerSource(
          sourceId: id,
          portal: fields['portal']!,
          mac: fields['mac']!,
          extraEpgUrls: extraEpgUrls,
          catchupTimezone: catchupTimezone,
          catchupOffsetMinutes: catchupOffsetMinutes,
          catchupMaxDays: catchupMaxDays,
          displayName: name,
        );
      case SourceKind.xtream:
        return XtreamSource(
          sourceId: id,
          host: fields['host']!,
          username: fields['username']!,
          password: fields['password']!,
          // Per-source escape hatch over the platform default (`ts`, or `m3u8`
          // on iOS so live routes to AVPlayer rather than the SDR mpv
          // fallback — docs/ios.md "The `streamExtension` lever"). Needed
          // because a panel that doesn't serve the chosen container answers
          // 404, which is a dead channel rather than a degraded one; an
          // unrecognised value falls back to the platform default.
          streamExtension: settings['streamExtension']?.toString(),
          extraEpgUrls: extraEpgUrls,
          playlistExpiryHint: fields['playlistExpiryHint'],
          catchupTimezone: catchupTimezone,
          catchupOffsetMinutes: catchupOffsetMinutes,
          catchupMaxDays: catchupMaxDays,
          displayName: name,
        );
      case SourceKind.m3u:
        return M3uSource(
          sourceId: id,
          playlistUrl: fields['playlistUrl']!,
          epgUrl: _opt('epgUrl'),
          extraEpgUrls: extraEpgUrls,
          userAgent: _opt('userAgent'),
          catchupTimezone: catchupTimezone,
          catchupOffsetMinutes: catchupOffsetMinutes,
          catchupMaxDays: catchupMaxDays,
          displayName: name,
        );
      case SourceKind.demo:
        return DemoSource(sourceId: id, displayName: name);
    }
  }

  /// Cache namespace used by releases before PR4. Read only during the atomic
  /// migration to [id]; never use this as a new persisted identity.
  String get legacyCacheId => switch (kind) {
    SourceKind.stalker => 'stalker:${fields['portal']}|${fields['mac']}',
    SourceKind.xtream =>
      'xtream:${_legacyXtreamBase(fields['host'] ?? '')}|${fields['username']}',
    SourceKind.m3u => 'm3u:${fields['playlistUrl']}',
    SourceKind.demo => 'demo',
  };

  String? _opt(String key) {
    final v = fields[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// The aspect mode this source's player last used, as the mode's label
  /// (`Fit`/`Fill`/`Stretch`/`16:9`/`4:3`), or null if the user has never
  /// chosen one — in which case the player picks a platform-appropriate
  /// default.
  ///
  /// Stored per source rather than globally for the same reason the buffer
  /// preset is: it rides the existing `settings` blob into the cloud, needs no
  /// new storage, and a user with an SD-heavy provider and an HD one may well
  /// want different framing for each. Broad, not secret — it is a preference,
  /// not a credential.
  String? get aspectModeLabel {
    final value = settings['aspectMode']?.toString();
    return (value == null || value.isEmpty) ? null : value;
  }

  /// How much media the players hold ahead of playback for this source, as
  /// the stored preset name (`low`/`normal`/`high`; anything else, including a
  /// value a newer build wrote, reads as `normal`).
  ///
  /// Lives in `settings` rather than `fields` because it is a plain preference,
  /// not a credential — so it rides the source row into the cloud like the
  /// catch-up overrides and `streamExtension` do. Kept as the raw name here so
  /// this layer needs no dependency on `lib/player/`; callers parse it with
  /// `bufferPresetFromName`.
  String get bufferPresetName {
    final value = settings['bufferPreset']?.toString().toLowerCase();
    return const {'low', 'normal', 'high'}.contains(value) ? value! : 'normal';
  }

  /// Extra XMLTV guide URLs, one per line in `fields['epgUrls']`.
  ///
  /// A newline-separated blob rather than JSON because [fields] is
  /// `Map<String, String>` and a URL cannot contain a newline, so the encoding
  /// is unambiguous without an escaping layer the panel would have to mirror.
  ///
  /// A **new** key rather than a list-shaped `epgUrl`: `epgUrl` is read as a
  /// single URL by every already-published build, and those builds pull this
  /// source from the cloud. Widening it in place would hand them a blob they'd
  /// fetch as one URL and lose their guide over; leaving `epgUrl` alone means
  /// an older build keeps working on the first guide and simply doesn't see the
  /// rest. It is a **secret** key (see `secret_keys.dart`) — these URLs carry
  /// provider credentials as often as the playlist does.
  List<String> get extraEpgUrls {
    final raw = fields['epgUrls'];
    if (raw == null || raw.isEmpty) return const [];
    return [
      for (final line in raw.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  SourceConfig copyWith({
    String? id,
    SourceKind? kind,
    String? label,
    Map<String, String>? fields,
    Map<String, dynamic>? settings,
  }) => SourceConfig(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    label: label ?? this.label,
    fields: fields ?? this.fields,
    settings: settings ?? this.settings,
  );

  /// Category ids the user has hidden for [kind] (live channels / movies /
  /// series). Empty when nothing is hidden. Reads the JSON-shaped
  /// `settings['hiddenCategories'][kind.name]`.
  Set<String> hiddenCategoryIds(ContentKind kind) {
    final hidden = settings['hiddenCategories'];
    if (hidden is! Map) return const {};
    final list = hidden[kind.name];
    if (list is! List) return const {};
    return list.map((e) => e.toString()).toSet();
  }

  /// A copy with [kind]'s hidden-category set replaced by [ids]. An empty set
  /// clears the entry (and the whole map when nothing remains hidden) so a
  /// fully-enabled source serializes back to no `settings`.
  SourceConfig withHiddenCategories(ContentKind kind, Set<String> ids) {
    final existing = settings['hiddenCategories'];
    final hidden = <String, dynamic>{
      if (existing is Map)
        for (final entry in existing.entries) entry.key.toString(): entry.value,
    };
    if (ids.isEmpty) {
      hidden.remove(kind.name);
    } else {
      hidden[kind.name] = (ids.toList()..sort());
    }
    final next = <String, dynamic>{...settings};
    if (hidden.isEmpty) {
      next.remove('hiddenCategories');
    } else {
      next['hiddenCategories'] = hidden;
    }
    return copyWith(settings: next);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    'fields': fields,
    // Omit when empty so legacy/preference-free configs serialize unchanged.
    if (settings.isNotEmpty) 'settings': settings,
  };

  // NOTE: cloud sync now sends the full `fields` (credentials included) in both
  // directions, with the server refusing to blank a stored non-empty value
  // (`merge_preserving_nonempty`). The former `cloudSafeFields` credential-strip
  // projection is intentionally gone; the future opt-in E2EE phase (Phase 3, see
  // docs/cloud-sync.md) will reintroduce a projection that encrypts the locator
  // fields rather than dropping them.

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
    id: j['id'] as String,
    kind: SourceKind.values.byName(j['kind'] as String),
    label: j['label'] as String,
    fields: Map<String, String>.from(j['fields'] as Map),
    settings: (j['settings'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

/// Whether [config] is missing a required credential/locator, i.e. it can't be
/// activated or played. This is exactly the state a cloud pull leaves a source
/// in when the profile is end-to-end encrypted and this device is **locked** (no
/// content key), or when a secret was never provisioned: the broad fields arrive
/// but the secret ones stay empty. Used to fail closed — the sources screen
/// badges such a source and refuses to activate it. Pure; no crypto/network.
bool sourceCredentialsMissing(SourceConfig config) {
  bool blank(String key) => (config.fields[key] ?? '').trim().isEmpty;
  switch (config.kind) {
    case SourceKind.stalker:
      return blank('portal') || blank('mac');
    case SourceKind.xtream:
      return blank('host') || blank('username') || blank('password');
    case SourceKind.m3u:
      return blank('playlistUrl');
    case SourceKind.demo:
      return false;
  }
}

String _legacyXtreamBase(String host) {
  var value = host.trim();
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'http://$value';
  }
  if (value.endsWith('/')) value = value.substring(0, value.length - 1);
  return value;
}
