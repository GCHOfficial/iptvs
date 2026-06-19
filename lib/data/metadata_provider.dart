import '../sources/source.dart';

abstract class MetadataProvider {
  String get provider;
  String get authMode;
  bool get ratingsOnly => false;

  Future<ExternalMetadata?> search(MediaItem item);

  void close();
}
