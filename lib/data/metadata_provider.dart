import '../sources/source.dart';

abstract class MetadataProvider {
  String get provider;
  String get authMode;

  Future<ExternalMetadata?> search(MediaItem item);

  void close();
}
