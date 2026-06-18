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
class DemoSource implements Source {
  @override
  String get id => 'demo';

  @override
  String get name => 'Demo · public test streams';

  static const _category = Category(id: 'test', title: 'Test streams');

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
  Future<List<Programme>> epg(List<Channel> channels) async => const [];

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      const [];

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async => const [];

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async =>
      throw UnsupportedError('Demo source only supports live channels');

  @override
  Future<void> dispose() async {}
}
