import 'package:flutter/foundation.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as tz;

import '../data/load_token.dart';

/// Provider-agnostic domain model + interface for an IPTV source.
///
/// Stalker, Xtream Codes, and M3U each implement [Source], so the rest of the
/// app never needs to know which kind of provider it's talking to. To add a
/// new provider you implement this one interface and change nothing else.

@immutable
class Category {
  final String id;
  final String title;
  const Category({required this.id, required this.title});
}

enum ContentKind { live, movie, series, season, episode }

/// The URL convention a provider uses for programmes in its archive.
enum CatchupUrlMode { unsupported, xtreamTimeshift, stalkerQuery, m3uTemplate }

enum CapabilityAvailability { supported, unavailable, unknown }

enum ResolutionCapability { providerDefined, playlistDefined, fixed, unknown }

enum SubscriptionExpiryKind { dated, unlimited, unknown }

/// Provider-reported subscription lifetime. A nullable [DateTime] cannot
/// distinguish an explicit non-expiring account from absent/unparseable
/// metadata, so source implementations return this three-state value.
@immutable
class SubscriptionExpiry {
  final SubscriptionExpiryKind kind;
  final DateTime? date;

  const SubscriptionExpiry._(this.kind, this.date);

  const SubscriptionExpiry.dated(DateTime date)
    : this._(SubscriptionExpiryKind.dated, date);
  const SubscriptionExpiry.unlimited()
    : this._(SubscriptionExpiryKind.unlimited, null);
  const SubscriptionExpiry.unknown()
    : this._(SubscriptionExpiryKind.unknown, null);

  bool get isUnlimited => kind == SubscriptionExpiryKind.unlimited;
}

/// Provider-owned capability summary used by source-management UX. `unknown`
/// is intentional: a saved M3U URL cannot truthfully advertise attributes that
/// are only discoverable after downloading its playlist.
@immutable
class SourceCapabilities {
  final CapabilityAvailability epg;
  final CapabilityAvailability catchup;
  final ResolutionCapability resolution;

  const SourceCapabilities({
    required this.epg,
    required this.catchup,
    required this.resolution,
  });
}

/// Provider-reported (or explicitly configured) catch-up behavior.  The UI
/// uses [supported] rather than attempting to infer support from URL failures.
@immutable
class CatchupCapability {
  final CatchupUrlMode mode;
  final String? timezone;
  final int? fixedOffsetMinutes;
  final Duration? maxArchiveWindow;
  final String startFormat;
  final String? endFormat;
  final String? template;

  const CatchupCapability({
    this.mode = CatchupUrlMode.unsupported,
    this.timezone,
    this.fixedOffsetMinutes,
    this.maxArchiveWindow,
    this.startFormat = 'yyyy-MM-dd:HH-mm',
    this.endFormat,
    this.template,
  });

  bool get supported => mode != CatchupUrlMode.unsupported;
  static const unsupported = CatchupCapability();
}

CatchupCapability catchupCapabilityOf(Source source) {
  if (source is CatchupSource) {
    return (source as CatchupSource).catchupCapability;
  }
  return CatchupCapability.unsupported;
}

/// Provider-agnostic access for callers holding the base [Source] type.
extension SourceCatchupCapability on Source {
  CatchupCapability get catchupCapability => catchupCapabilityOf(this);
}

/// Internal structural marker used by built-in providers. Kept separate from
/// [Source] so third-party/test implementations are not broken by capability
/// additions.
abstract interface class CatchupSource {
  CatchupCapability get catchupCapability;
}

abstract interface class SourceCapabilityReporter {
  SourceCapabilities get sourceCapabilities;
}

SourceCapabilities capabilitiesOf(Source source) =>
    source is SourceCapabilityReporter
    ? (source as SourceCapabilityReporter).sourceCapabilities
    : const SourceCapabilities(
        epg: CapabilityAvailability.unknown,
        catchup: CapabilityAvailability.unknown,
        resolution: ResolutionCapability.unknown,
      );

bool _timezonesInitialized = false;

void _ensureTimezonesInitialized() {
  if (_timezonesInitialized) return;
  timezone_data.initializeTimeZones();
  _timezonesInitialized = true;
}

bool isSupportedCatchupTimezone(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return true;
  if (RegExp(
    r'^(?:UTC|GMT)?[+-]\d{1,2}(?::?\d{2})?$',
    caseSensitive: false,
  ).hasMatch(normalized)) {
    return true;
  }
  if (const {'UTC', 'GMT', 'Z'}.contains(normalized.toUpperCase())) return true;
  _ensureTimezonesInitialized();
  try {
    tz.getLocation(normalized);
    return true;
  } on tz.LocationNotFoundException {
    return false;
  }
}

/// Converts an absolute programme instant to the provider's wall clock.
/// Fixed offsets are deterministic and are preferred for an explicit override;
/// `UTC` is also handled without consulting the device timezone.
DateTime catchupProviderTime(
  DateTime instant, {
  String? timezone,
  int? fixedOffsetMinutes,
}) {
  final utc = instant.toUtc();
  if (fixedOffsetMinutes != null) {
    return utc.add(Duration(minutes: fixedOffsetMinutes));
  }
  if (timezone == null || timezone.isEmpty) return instant.toLocal();
  final normalized = timezone.trim().toUpperCase();
  if (normalized == 'UTC' || normalized == 'GMT' || normalized == 'Z') {
    return utc;
  }
  final match = RegExp(
    r'^(?:UTC|GMT)?([+-])(\d{1,2})(?::?(\d{2}))?$',
  ).firstMatch(normalized);
  if (match != null) {
    final minutes =
        int.parse(match.group(2)!) * 60 + int.parse(match.group(3) ?? '0');
    return utc.add(
      Duration(minutes: match.group(1) == '-' ? -minutes : minutes),
    );
  }
  _ensureTimezonesInitialized();
  try {
    return tz.TZDateTime.from(utc, tz.getLocation(timezone.trim()));
  } on tz.LocationNotFoundException {
    // Invalid provider metadata must fail predictably instead of silently
    // applying the device timezone and constructing a wrong archive URL.
    throw ArgumentError.value(timezone, 'timezone', 'Unknown IANA timezone');
  }
}

String formatCatchupTime(
  DateTime instant,
  CatchupCapability capability, {
  String? format,
}) {
  final t = catchupProviderTime(
    instant,
    timezone: capability.timezone,
    fixedOffsetMinutes: capability.fixedOffsetMinutes,
  );
  String p(int n, [int width = 2]) => n.toString().padLeft(width, '0');
  final f = format ?? capability.startFormat;
  return f
      .replaceAll('yyyy', p(t.year, 4))
      .replaceAll('MM', p(t.month))
      .replaceAll('dd', p(t.day))
      .replaceAll('HH', p(t.hour))
      .replaceAll('mm', p(t.minute))
      .replaceAll('ss', p(t.second))
      .replaceAll('X', t.timeZoneOffset.inSeconds == 0 ? 'Z' : '');
}

@immutable
class MediaCategory {
  final String id;
  final String title;
  final ContentKind kind;

  const MediaCategory({
    required this.id,
    required this.title,
    required this.kind,
  });
}

@immutable
class Channel {
  final String id;
  final String name;
  final String? logo;
  final String? categoryId;
  final int? number;

  /// How many days of catch-up / archive TV this channel exposes (0 = none).
  /// First-class provider metadata — like [StreamInfo.isLive], it's set by the
  /// [Source] and read provider-agnostically by the UI, never inferred. The
  /// provider-specific bits needed to *build* an archive URL stay in [extra].
  final int archiveDays;

  /// Provider-specific payload the owning [Source] knows how to interpret in
  /// [Source.resolve] — e.g. Stalker's `cmd`, Xtream's stream id. Keeps
  /// provider details out of the shared model.
  final Map<String, dynamic> extra;

  const Channel({
    required this.id,
    required this.name,
    this.logo,
    this.categoryId,
    this.number,
    this.archiveDays = 0,
    this.extra = const {},
  });

  /// Whether this channel offers catch-up / archive playback.
  bool get hasArchive => archiveDays > 0;
}

/// Fallback archive window when a provider flags a channel as catch-up capable
/// but doesn't report how many days it retains. A conservative value so the
/// guide still offers catch-up (the archive URL is built from a programme's own
/// timestamp, not this count — this only bounds how far back the picker looks).
const kDefaultArchiveDays = 7;

@immutable
class MediaItem {
  final String id;
  final String title;
  final ContentKind kind;
  final String? parentId;
  final String? categoryId;
  final String? poster;
  final String? backdrop;
  final String? description;
  final String? year;
  final double? rating;
  final int? durationSeconds;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? providerId;
  final Map<String, dynamic> extra;

  const MediaItem({
    required this.id,
    required this.title,
    required this.kind,
    this.parentId,
    this.categoryId,
    this.poster,
    this.backdrop,
    this.description,
    this.year,
    this.rating,
    this.durationSeconds,
    this.seasonNumber,
    this.episodeNumber,
    this.providerId,
    this.extra = const {},
  });

  MediaItem copyWith({
    String? id,
    String? title,
    ContentKind? kind,
    String? parentId,
    String? categoryId,
    String? poster,
    String? backdrop,
    String? description,
    String? year,
    double? rating,
    int? durationSeconds,
    int? seasonNumber,
    int? episodeNumber,
    String? providerId,
    Map<String, dynamic>? extra,
  }) => MediaItem(
    id: id ?? this.id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    parentId: parentId ?? this.parentId,
    categoryId: categoryId ?? this.categoryId,
    poster: poster ?? this.poster,
    backdrop: backdrop ?? this.backdrop,
    description: description ?? this.description,
    year: year ?? this.year,
    rating: rating ?? this.rating,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    seasonNumber: seasonNumber ?? this.seasonNumber,
    episodeNumber: episodeNumber ?? this.episodeNumber,
    providerId: providerId ?? this.providerId,
    extra: extra ?? this.extra,
  );
}

@immutable
class MediaPage {
  final List<MediaItem> items;
  final int page;
  final int totalPages;

  const MediaPage({
    required this.items,
    required this.page,
    required this.totalPages,
  });

  bool get hasMore => page < totalPages;
}

@immutable
class ExternalMetadata {
  final String provider;
  final String providerKey;
  final String? title;
  final String? overview;
  final String? poster;
  final String? backdrop;
  final String? year;
  final double? rating;
  final Map<String, dynamic> payload;
  final DateTime refreshedAt;

  const ExternalMetadata({
    required this.provider,
    required this.providerKey,
    this.title,
    this.overview,
    this.poster,
    this.backdrop,
    this.year,
    this.rating,
    this.payload = const {},
    required this.refreshedAt,
  });
}

/// A resolved, playable stream: the URL plus any HTTP headers the player must
/// send (User-Agent, Referer, etc.). Stalker and Xtream often need a MAG
/// User-Agent here; M3U usually needs nothing.
///
/// [isLive] is set by the owning [Source] — liveness is provider metadata, not
/// something to infer from the stream (an HLS live window reports a finite
/// duration, which looks just like VOD). Live streams get no seek bar; VOD does.
@immutable
class StreamSubtitle {
  final String url;
  final String label;
  final String? language;

  const StreamSubtitle({required this.url, required this.label, this.language});
}

@immutable
class StreamInfo {
  final String url;
  final Map<String, String> headers;
  final bool isLive;
  final List<StreamSubtitle> subtitles;
  const StreamInfo({
    required this.url,
    this.headers = const {},
    this.isLive = true,
    this.subtitles = const [],
  });
}

@immutable
class Programme {
  final String channelId;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;

  const Programme({
    required this.channelId,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
  });
}

abstract class Source {
  /// Stable identifier, used as the cache key for this source's data.
  String get id;

  /// Display name for the UI.
  String get name;

  /// Authenticate / prepare the source. For M3U this may be a no-op.
  Future<void> connect();

  /// Live TV categories.
  Future<List<Category>> categories();

  /// Channels, optionally filtered to a single category.
  Future<List<Channel>> channels({String? categoryId});

  /// Turn a channel into a playable stream. For Stalker this is where
  /// create_link is called — the URL is short-lived, so resolve at play time,
  /// never ahead of it.
  Future<StreamInfo> resolve(Channel channel);

  /// Resolve a *past* [programme] on [channel] into a playable catch-up /
  /// archive stream — [StreamInfo.isLive] is false, so it plays with a finite
  /// seek bar. Resolve at play time, like [resolve] (archive URLs are as
  /// short-lived as live ones). Only called for channels with
  /// [Channel.hasArchive]; sources without catch-up throw.
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('$runtimeType does not support catch-up');

  /// Electronic program guide for roughly the next few hours, given the
  /// source's [channels] (XMLTV sources need them to map tvg-id → channel id;
  /// Stalker ignores them and keys by channel id directly). Programmes are
  /// keyed via [Programme.channelId]. Sources without EPG return an empty list.
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final items = await mediaItems(
      kind,
      categoryId: categoryId,
      parent: parent,
    );
    return MediaPage(items: items, page: page, totalPages: page);
  }

  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final page = await mediaItemsPage(kind, categoryId: categoryId);
    return page.items
        .where((item) => item.title.toLowerCase().contains(q))
        .toList();
  }

  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('This source does not support ${item.kind.name}');

  /// Release any held resources.
  Future<void> dispose() async {}

  /// The subscription's dated, unlimited, or unknown expiry state.
  /// Implementations must redact any URL that reaches a log or error.
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();
}

/// Optional capability a [Source] can additionally implement to stream a
/// large XMLTV guide as bounded batches instead of building one big
/// [Programme] list in memory — see `LibraryRepository._ensureEpg` and
/// `AppDatabase.replaceEpgStream`.
///
/// Deliberately a *separate* interface rather than a defaulted member on
/// [Source] itself: every [Source] implementation in this codebase declares
/// `implements Source` (not `extends`), and Dart does not inherit default
/// method bodies through `implements` — every member of the interface must be
/// redeclared by the implementer regardless of whether the interface gives it
/// a body. Adding a member directly to [Source] would therefore force every
/// implementer, including ones with no batched path (Stalker, Demo), to
/// redeclare it just to keep compiling. A source without this capability (the
/// common case) simply doesn't implement [BatchedEpgSource]; the repository
/// falls back to [Source.epg].
abstract interface class BatchedEpgSource {
  /// Streamed counterpart of [Source.epg]: batches of [Programme]s for
  /// [channels], or null when this source has no EPG configured (mirrors
  /// [Source.epg]'s empty-list return for that case — the repository treats
  /// null exactly like an empty [Source.epg] result and falls back to it).
  /// [token], when given, lets the caller cooperatively cancel a stale
  /// in-flight load; a cancelled stream ends in an error rather than
  /// completing normally (see `LoadCancelledException`).
  Stream<List<Programme>>? epgBatched(
    List<Channel> channels, {
    LoadToken? token,
  });
}
