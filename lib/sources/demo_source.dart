import 'source.dart';

/// A built-in source of public, legally-free HLS test streams.
///
/// Lets you develop and exercise the player without any real provider. Swap it
/// out for a StalkerSource / XtreamSource / M3uSource later — the rest of the
/// app only depends on [Source], so nothing else changes.
///
/// These are well-known public test streams (Mux's hls.js test set, Apple's
/// HLS examples, Blender open movies). They're intended for testing and may
/// occasionally be down; swap any that misbehave.
class DemoSource implements Source, CatchupSource {
  DemoSource({this.sourceId = 'demo', this.displayName});

  final String sourceId;

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => sourceId;

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'Demo · public test streams';

  @override
  CatchupCapability get catchupCapability => CatchupCapability.unsupported;

  static const _category = Category(id: 'test', title: 'Test streams');
  static const _mediaCategory = MediaCategory(
    id: 'demo-series',
    title: 'Demo series',
    kind: ContentKind.series,
  );

  static const _channels = <Channel>[
    Channel(
      id: 'bbb',
      name: 'Big Buck Bunny (H.264 — baseline)',
      categoryId: 'test',
      number: 1,
    ),
    Channel(
      id: 'bipbop',
      name: 'Apple BipBop (H.264)',
      categoryId: 'test',
      number: 2,
    ),
    Channel(
      id: 'tos',
      name: 'Tears of Steel (H.264)',
      categoryId: 'test',
      number: 3,
    ),
    Channel(
      id: 'bipbop_hevc',
      name: 'Apple BipBop (HEVC — codec test)',
      categoryId: 'test',
      number: 4,
    ),
  ];

  static const _urls = <String, String>{
    'bbb': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    'bipbop':
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
    'tos': 'https://test-streams.mux.dev/tos_ismc/main.m3u8',
    // HEVC: software-decodes (slow) without GPU acceleration — e.g. inside a VM.
    'bipbop_hevc':
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8',
  };

  static const _series = MediaItem(
    id: 'demo-series-1',
    title: 'Codec Test Series',
    kind: ContentKind.series,
    categoryId: 'demo-series',
    description: 'Public test streams grouped as a demo series.',
    year: '2026',
  );

  static const _season = MediaItem(
    id: 'demo-series-1:season:1',
    title: 'Season 1',
    kind: ContentKind.season,
    parentId: 'demo-series-1',
    seasonNumber: 1,
  );

  static const _episodes = <MediaItem>[
    MediaItem(
      id: 'bbb',
      title: 'Big Buck Bunny',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      seasonNumber: 1,
      episodeNumber: 1,
      description: 'H.264 baseline HLS test stream.',
      extra: {'urlKey': 'bbb'},
    ),
    MediaItem(
      id: 'bipbop',
      title: 'Apple BipBop',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      seasonNumber: 1,
      episodeNumber: 2,
      description: 'Apple fMP4 HLS test stream.',
      extra: {'urlKey': 'bipbop'},
    ),
    MediaItem(
      id: 'tos',
      title: 'Tears of Steel',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      seasonNumber: 1,
      episodeNumber: 3,
      description: 'Open movie HLS test stream.',
      extra: {'urlKey': 'tos'},
    ),
  ];

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [_category];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => _channels
      .where((c) => categoryId == null || c.categoryId == categoryId)
      .toList();

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final url = _urls[channel.id];
    if (url == null) {
      throw StateError('No stream URL for channel "${channel.id}"');
    }
    return StreamInfo(url: url, isLive: false);
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async => throw UnsupportedError('DemoSource does not support catch-up');

  @override
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      kind == ContentKind.series ? const [_mediaCategory] : const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    if (kind == ContentKind.series) return const [_series];
    if (kind == ContentKind.season && parent?.id == _series.id) {
      return const [_season];
    }
    if (kind == ContentKind.episode && parent?.id == _season.id) {
      return _episodes;
    }
    return const [];
  }

  @override
  Future<MediaPage> mediaItemsPage(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int page = 1,
  }) async {
    final items = page == 1
        ? await mediaItems(kind, categoryId: categoryId, parent: parent)
        : const <MediaItem>[];
    return MediaPage(items: items, page: page, totalPages: 1);
  }

  @override
  Future<List<MediaItem>> searchMedia(
    ContentKind kind,
    String query, {
    String? categoryId,
  }) async {
    if (kind != ContentKind.series) return const [];
    return _series.title.toLowerCase().contains(query.trim().toLowerCase())
        ? const [_series]
        : const [];
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.episode) {
      throw UnsupportedError('Demo source only supports episode playback');
    }
    final urlKey = item.extra['urlKey']?.toString() ?? item.id;
    final url = _urls[urlKey];
    if (url == null) {
      throw StateError('No stream URL for episode "${item.id}"');
    }
    return StreamInfo(url: url, isLive: false);
  }

  @override
  Future<DateTime?> subscriptionExpiry() async => null;

  @override
  Future<void> dispose() async {}
}
