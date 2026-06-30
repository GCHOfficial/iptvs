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
    switch (kind) {
      case SourceKind.stalker:
        return StalkerSource(
          portal: fields['portal']!,
          mac: fields['mac']!,
          displayName: name,
        );
      case SourceKind.xtream:
        return XtreamSource(
          host: fields['host']!,
          username: fields['username']!,
          password: fields['password']!,
          displayName: name,
        );
      case SourceKind.m3u:
        return M3uSource(
          playlistUrl: fields['playlistUrl']!,
          epgUrl: _opt('epgUrl'),
          userAgent: _opt('userAgent'),
          displayName: name,
        );
      case SourceKind.demo:
        return DemoSource(displayName: name);
    }
  }

  String? _opt(String key) {
    final v = fields[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  SourceConfig copyWith({
    String? id,
    SourceKind? kind,
    String? label,
    Map<String, String>? fields,
    Map<String, dynamic>? settings,
  }) =>
      SourceConfig(
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

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
        id: j['id'] as String,
        kind: SourceKind.values.byName(j['kind'] as String),
        label: j['label'] as String,
        fields: Map<String, String>.from(j['fields'] as Map),
        settings:
            (j['settings'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}
