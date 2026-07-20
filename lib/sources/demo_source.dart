import 'source.dart';

/// A built-in catalogue of public test streams and freely licensed films.
///
/// The catalogue is deliberately broader than a playback smoke test: it
/// exercises live/VOD presentation, EPG and archive UI, category filtering,
/// movie metadata, series/season/episode browsing, HLS, fMP4, HEVC and plain
/// MP4. Blender titles are streamed from Blender's official video service and
/// remain subject to their Creative Commons attribution licences. Apple and
/// Mux entries are public protocol test fixtures and are labelled as such.
///
/// Remote fixtures can occasionally be unavailable, so callers should still
/// handle ordinary playback/network errors.
class DemoSource implements Source, CatchupSource, SourceCapabilityReporter {
  DemoSource({this.sourceId = 'demo', this.displayName});

  final String sourceId;

  /// User-assigned label (from SourceConfig); preferred over the derived name.
  final String? displayName;

  @override
  String get id => sourceId;

  @override
  String get name => displayName?.trim().isNotEmpty == true
      ? displayName!.trim()
      : 'Demo · open media & test streams';

  @override
  CatchupCapability get catchupCapability => const CatchupCapability(
    // The demo resolves its simulated archive itself. A supported mode is
    // still reported so the provider-agnostic UI exposes its catch-up paths.
    mode: CatchupUrlMode.m3uTemplate,
    timezone: 'UTC',
    maxArchiveWindow: Duration(days: 1),
  );

  @override
  SourceCapabilities get sourceCapabilities => const SourceCapabilities(
    epg: CapabilityAvailability.supported,
    catchup: CapabilityAvailability.supported,
    resolution: ResolutionCapability.fixed,
  );

  static const _openLiveCategory = Category(
    id: 'open-simulcasts',
    title: 'Open movie simulcasts',
  );
  static const _labLiveCategory = Category(
    id: 'playback-lab',
    title: 'Playback lab',
  );

  static const _openAnimation = MediaCategory(
    id: 'open-animation',
    title: 'Open animation',
    kind: ContentKind.movie,
  );
  static const _openSciFi = MediaCategory(
    id: 'open-scifi',
    title: 'Open science fiction',
    kind: ContentKind.movie,
  );
  static const _testSeriesCategory = MediaCategory(
    id: 'demo-series',
    title: 'Playback test series',
    kind: ContentKind.series,
  );
  static const _openSeriesCategory = MediaCategory(
    id: 'open-series',
    title: 'Open animated series',
    kind: ContentKind.series,
  );

  static const _bbbArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      'bf1f3fb5-b119-4f9f-9930-8e20e892b898.jpg';
  static const _sintelArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      '0eb052d0-fd51-43e6-aa33-ecdbf77a5d40.jpg';
  static const _tearsArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      '8533ea43-4271-4a57-9694-e9d0b35e1aa1.jpg';
  static const _springArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      '3d95fb3d-c866-42c8-9db1-fe82f48ccb95.jpg';
  static const _granDillamaArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      'fb70d459-48d2-4db5-adba-813c84f9200a.jpg';
  static const _llamigosArt =
      'https://video.blender.org/lazy-static/thumbnails/'
      '23f3ef79-15dc-44c5-aa45-cf92e78a4509.jpg';

  static const _channels = <Channel>[
    Channel(
      id: 'bbb',
      name: 'Big Buck Bunny (H.264)',
      logo: _bbbArt,
      categoryId: 'open-simulcasts',
      number: 1,
      archiveDays: 1,
      extra: {'urlKey': 'bbb', 'isLive': true},
    ),
    Channel(
      id: 'tos',
      name: 'Tears of Steel (H.264)',
      logo: _tearsArt,
      categoryId: 'open-simulcasts',
      number: 2,
      archiveDays: 1,
      extra: {'urlKey': 'tos', 'isLive': true},
    ),
    Channel(
      id: 'bipbop',
      name: 'Apple BipBop · AVC/fMP4',
      categoryId: 'playback-lab',
      number: 101,
      extra: {'urlKey': 'bipbop', 'isLive': false},
    ),
    Channel(
      id: 'bipbop_hevc',
      name: 'Apple BipBop · HEVC',
      categoryId: 'playback-lab',
      number: 102,
      extra: {'urlKey': 'bipbop_hevc', 'isLive': false},
    ),
    Channel(
      id: 'sintel_trailer',
      name: 'Sintel trailer · progressive MP4',
      logo: _sintelArt,
      categoryId: 'playback-lab',
      number: 103,
      extra: {'urlKey': 'sintel_trailer', 'isLive': false},
    ),
    Channel(
      id: 'peertube_hls',
      name: 'Blender Video · HLS master',
      logo: _llamigosArt,
      categoryId: 'playback-lab',
      number: 104,
      extra: {'urlKey': 'peertube_hls', 'isLive': false},
    ),
  ];

  static const _urls = <String, String>{
    // Public HLS protocol fixtures.
    'bbb': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
    'bipbop':
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
        'img_bipbop_adv_example_fmp4/master.m3u8',
    'tos': 'https://test-streams.mux.dev/tos_ismc/main.m3u8',
    'bipbop_hevc':
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
        'bipbop_adv_example_hevc/master.m3u8',
    'sintel_trailer':
        'https://download.blender.org/durian/trailer/'
        'sintel_trailer-480p.mp4',
    'peertube_hls':
        'https://video.blender.org/object-storage/streaming_playlists/hls/'
        '515fa4ff-7038-42a3-9e1b-ef7154bd7398/'
        '8fa0e174-2a83-4197-98ae-f2d0efdead78-master.m3u8',

    // Official Blender Video encodes of Creative Commons open movies.
    'movie_bbb':
        'https://video.blender.org/object-storage/web_videos/'
        'bf1f3fb5-b119-4f9f-9930-8e20e892b898-720.mp4',
    'movie_sintel':
        'https://video.blender.org/object-storage/web_videos/'
        '0eb052d0-fd51-43e6-aa33-ecdbf77a5d40-818.mp4',
    'movie_tos':
        'https://video.blender.org/object-storage/web_videos/'
        '8533ea43-4271-4a57-9694-e9d0b35e1aa1-800.mp4',
    'movie_spring':
        'https://video.blender.org/object-storage/web_videos/'
        '3d95fb3d-c866-42c8-9db1-fe82f48ccb95-804.mp4',
    'caminandes_2':
        'https://video.blender.org/object-storage/web_videos/'
        'fb70d459-48d2-4db5-adba-813c84f9200a-1080.mp4',
    'caminandes_3':
        'https://video.blender.org/object-storage/web_videos/'
        '23f3ef79-15dc-44c5-aa45-cf92e78a4509-1080.mp4',
  };

  // Ratings are deliberately populated to exercise the rating UI; they are
  // fixture values, not an assertion that the app is an authoritative rating
  // provider.
  static const _movies = <MediaItem>[
    MediaItem(
      id: 'movie-bbb',
      title: 'Big Buck Bunny',
      kind: ContentKind.movie,
      categoryId: 'open-animation',
      poster: _bbbArt,
      backdrop: _bbbArt,
      description:
          'A gentle giant rabbit turns the tables on three woodland bullies. '
          'Blender Foundation open movie, CC BY 3.0.',
      year: '2008',
      rating: 7.4,
      durationSeconds: 596,
      extra: {'urlKey': 'movie_bbb', 'license': 'CC BY 3.0'},
    ),
    MediaItem(
      id: 'movie-sintel',
      title: 'Sintel',
      kind: ContentKind.movie,
      categoryId: 'open-animation',
      poster: _sintelArt,
      backdrop: _sintelArt,
      description:
          'A lone warrior searches for a dragon she befriended long ago. '
          'Blender Foundation open movie, CC BY 3.0.',
      year: '2010',
      rating: 7.5,
      durationSeconds: 888,
      extra: {'urlKey': 'movie_sintel', 'license': 'CC BY 3.0'},
    ),
    MediaItem(
      id: 'movie-tos',
      title: 'Tears of Steel',
      kind: ContentKind.movie,
      categoryId: 'open-scifi',
      poster: _tearsArt,
      backdrop: _tearsArt,
      description:
          'Scientists and warriors stage a desperate encounter in a future '
          'Amsterdam. Blender Foundation open movie, CC BY 3.0.',
      year: '2012',
      rating: 6.6,
      durationSeconds: 734,
      extra: {'urlKey': 'movie_tos', 'license': 'CC BY 3.0'},
    ),
    MediaItem(
      id: 'movie-spring',
      title: 'Spring',
      kind: ContentKind.movie,
      categoryId: 'open-animation',
      poster: _springArt,
      backdrop: _springArt,
      description:
          'A shepherd girl and her dog face ancient spirits to continue the '
          'cycle of life. Blender Studio open movie, CC BY-SA.',
      year: '2019',
      rating: 7.8,
      durationSeconds: 464,
      extra: {'urlKey': 'movie_spring', 'license': 'CC BY-SA'},
    ),
  ];

  // Keep this id/title stable: widget and repository tests intentionally use
  // it as their known series hierarchy fixture.
  static const _codecSeries = MediaItem(
    id: 'demo-series-1',
    title: 'Codec Test Series',
    kind: ContentKind.series,
    categoryId: 'demo-series',
    poster: _bbbArt,
    backdrop: _tearsArt,
    description:
        'Two seasons of public playback fixtures covering adaptive HLS, '
        'fMP4, HEVC and progressive MP4.',
    year: '2026',
    rating: 8.0,
  );

  static const _caminandesSeries = MediaItem(
    id: 'caminandes',
    title: 'Caminandes',
    kind: ContentKind.series,
    categoryId: 'open-series',
    poster: _llamigosArt,
    backdrop: _granDillamaArt,
    description:
        'Koro the llama discovers that the road is never as easy as it looks. '
        'Blender Foundation animated shorts, CC BY 3.0.',
    year: '2013',
    rating: 7.6,
  );

  static const _codecSeason1 = MediaItem(
    id: 'demo-series-1:season:1',
    title: 'Season 1',
    kind: ContentKind.season,
    parentId: 'demo-series-1',
    seasonNumber: 1,
    poster: _bbbArt,
  );
  static const _codecSeason2 = MediaItem(
    id: 'demo-series-1:season:2',
    title: 'Modern codecs & containers',
    kind: ContentKind.season,
    parentId: 'demo-series-1',
    seasonNumber: 2,
    poster: _sintelArt,
  );
  static const _caminandesSeason = MediaItem(
    id: 'caminandes:season:1',
    title: 'Open shorts',
    kind: ContentKind.season,
    parentId: 'caminandes',
    seasonNumber: 1,
    poster: _llamigosArt,
  );

  static const _codecSeason1Episodes = <MediaItem>[
    MediaItem(
      id: 'bbb',
      title: 'Big Buck Bunny',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      poster: _bbbArt,
      backdrop: _bbbArt,
      seasonNumber: 1,
      episodeNumber: 1,
      description: 'Mux multi-bitrate H.264 HLS test stream.',
      durationSeconds: 634,
      extra: {'urlKey': 'bbb'},
    ),
    MediaItem(
      id: 'bipbop',
      title: 'Apple BipBop',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      seasonNumber: 1,
      episodeNumber: 2,
      description:
          'Apple AVC/fMP4 HLS example with alternate renditions and subtitles.',
      extra: {'urlKey': 'bipbop'},
    ),
    MediaItem(
      id: 'tos',
      title: 'Tears of Steel',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:1',
      poster: _tearsArt,
      backdrop: _tearsArt,
      seasonNumber: 1,
      episodeNumber: 3,
      description: 'Open movie packaged as an HLS compatibility fixture.',
      durationSeconds: 734,
      extra: {'urlKey': 'tos'},
    ),
  ];

  static const _codecSeason2Episodes = <MediaItem>[
    MediaItem(
      id: 'bipbop_hevc_episode',
      title: 'Apple BipBop · HEVC',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:2',
      seasonNumber: 2,
      episodeNumber: 1,
      description:
          'HEVC HLS fixture for hardware/software decoder and fallback tests.',
      extra: {'urlKey': 'bipbop_hevc'},
    ),
    MediaItem(
      id: 'sintel_trailer_episode',
      title: 'Sintel trailer · MP4',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:2',
      poster: _sintelArt,
      backdrop: _sintelArt,
      seasonNumber: 2,
      episodeNumber: 2,
      description: 'Official Blender-hosted progressive H.264 MP4 fixture.',
      durationSeconds: 52,
      extra: {'urlKey': 'sintel_trailer'},
    ),
    MediaItem(
      id: 'peertube_hls_episode',
      title: 'Blender Video · HLS master',
      kind: ContentKind.episode,
      parentId: 'demo-series-1:season:2',
      poster: _llamigosArt,
      backdrop: _llamigosArt,
      seasonNumber: 2,
      episodeNumber: 3,
      description: 'PeerTube-generated adaptive HLS master playlist.',
      durationSeconds: 286,
      extra: {'urlKey': 'peertube_hls'},
    ),
  ];

  static const _caminandesEpisodes = <MediaItem>[
    MediaItem(
      id: 'caminandes-2',
      title: 'Gran Dillama',
      kind: ContentKind.episode,
      parentId: 'caminandes:season:1',
      poster: _granDillamaArt,
      backdrop: _granDillamaArt,
      seasonNumber: 1,
      episodeNumber: 1,
      description:
          'Koro wants to cross a road, but an armadillo has other ideas. '
          'CC BY 3.0.',
      year: '2013',
      durationSeconds: 146,
      extra: {'urlKey': 'caminandes_2', 'license': 'CC BY 3.0'},
    ),
    MediaItem(
      id: 'caminandes-3',
      title: 'Llamigos',
      kind: ContentKind.episode,
      parentId: 'caminandes:season:1',
      poster: _llamigosArt,
      backdrop: _llamigosArt,
      seasonNumber: 1,
      episodeNumber: 2,
      description:
          'Koro meets Oti and competes for a tempting red berry. CC BY 3.0.',
      year: '2016',
      durationSeconds: 150,
      extra: {'urlKey': 'caminandes_3', 'license': 'CC BY 3.0'},
    ),
  ];

  @override
  Future<void> connect() async {}

  @override
  Future<List<Category>> categories() async => const [
    _openLiveCategory,
    _labLiveCategory,
  ];

  @override
  Future<List<Channel>> channels({String? categoryId}) async => _channels
      .where(
        (channel) => categoryId == null || channel.categoryId == categoryId,
      )
      .toList(growable: false);

  @override
  Future<StreamInfo> resolve(Channel channel) async {
    final url = _urlFor(channel.extra['urlKey']?.toString() ?? channel.id);
    return StreamInfo(url: url, isLive: channel.extra['isLive'] == true);
  }

  @override
  Future<StreamInfo> resolveArchive(
    Channel channel,
    Programme programme,
  ) async {
    if (!channel.hasArchive || programme.channelId != channel.id) {
      throw UnsupportedError('This demo channel has no matching archive');
    }
    final url = _urlFor(channel.extra['urlKey']?.toString() ?? channel.id);
    return StreamInfo(url: url, isLive: false);
  }

  @override
  Future<List<Programme>> epg(List<Channel> channels) async {
    final now = DateTime.now();
    final slot = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute < 30 ? 0 : 30,
    );
    return [
      for (final channel in channels)
        for (var offset = -4; offset <= 4; offset++)
          Programme(
            channelId: channel.id,
            start: slot.add(Duration(minutes: offset * 30)),
            stop: slot.add(Duration(minutes: (offset + 1) * 30)),
            title: _programmeTitle(channel, offset),
            description: offset < 0
                ? 'Past demo programme — available as simulated catch-up on '
                      'the open-movie channels.'
                : 'Generated locally so now/next and guide navigation remain '
                      'testable without a guide provider.',
          ),
    ];
  }

  @override
  Future<List<MediaCategory>> mediaCategories(ContentKind kind) async =>
      switch (kind) {
        ContentKind.movie => const [_openAnimation, _openSciFi],
        ContentKind.series => const [_testSeriesCategory, _openSeriesCategory],
        _ => const [],
      };

  @override
  Future<List<MediaItem>> mediaItems(
    ContentKind kind, {
    String? categoryId,
    MediaItem? parent,
    int? maxPages,
  }) async {
    final items = switch (kind) {
      ContentKind.movie => _movies,
      ContentKind.series => const [_codecSeries, _caminandesSeries],
      ContentKind.season when parent?.id == _codecSeries.id => const [
        _codecSeason1,
        _codecSeason2,
      ],
      ContentKind.season when parent?.id == _caminandesSeries.id => const [
        _caminandesSeason,
      ],
      ContentKind.episode when parent?.id == _codecSeason1.id =>
        _codecSeason1Episodes,
      ContentKind.episode when parent?.id == _codecSeason2.id =>
        _codecSeason2Episodes,
      ContentKind.episode when parent?.id == _caminandesSeason.id =>
        _caminandesEpisodes,
      _ => const <MediaItem>[],
    };
    return items
        .where((item) => categoryId == null || item.categoryId == categoryId)
        .toList(growable: false);
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
    if (kind != ContentKind.movie && kind != ContentKind.series) {
      return const [];
    }
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return const [];
    final items = await mediaItems(kind, categoryId: categoryId);
    return items
        .where((item) => item.title.toLowerCase().contains(normalized))
        .toList(growable: false);
  }

  @override
  Future<MediaItem> mediaDetails(MediaItem item) async => item;

  @override
  Future<StreamInfo> resolveMedia(MediaItem item) async {
    if (item.kind != ContentKind.movie && item.kind != ContentKind.episode) {
      throw UnsupportedError('Demo source cannot play ${item.kind.name} rows');
    }
    final urlKey = item.extra['urlKey']?.toString() ?? item.id;
    return StreamInfo(url: _urlFor(urlKey), isLive: false);
  }

  static String _urlFor(String key) {
    final url = _urls[key];
    if (url == null) throw StateError('No demo stream URL for "$key"');
    return url;
  }

  static String _programmeTitle(Channel channel, int offset) {
    final label = offset == 0
        ? 'Now'
        : offset == 1
        ? 'Up next'
        : offset < 0
        ? 'Replay ${offset.abs()}'
        : 'Later $offset';
    final shortName = channel.name.split(' · ').first;
    return '$shortName — $label';
  }

  @override
  Future<SubscriptionExpiry> subscriptionExpiry() async =>
      const SubscriptionExpiry.unknown();

  @override
  Future<void> dispose() async {}
}
