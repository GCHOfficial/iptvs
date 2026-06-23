import '../sources/source.dart';

abstract class MetadataProvider {
  String get provider;
  String get authMode;
  bool get ratingsOnly => false;

  Future<ExternalMetadata?> search(MediaItem item);

  Future<ExternalMetadata?> seasonMetadata(
    MediaItem series,
    MediaItem season,
  ) async => null;

  Future<ExternalMetadata?> episodeMetadata(
    MediaItem season,
    MediaItem episode,
  ) async => null;

  void close();
}
