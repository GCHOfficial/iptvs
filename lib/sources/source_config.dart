import 'demo_source.dart';
import 'm3u_source.dart';
import 'source.dart';
import 'stalker_source.dart';
import 'xtream_source.dart';

enum SourceKind { stalker, xtream, m3u, demo }

/// A saved, serializable provider configuration. [build] turns it into a live
/// [Source]. Stored (including credentials) via the SourceStore.
class SourceConfig {
  final String id;
  final SourceKind kind;
  final String label;
  final Map<String, String> fields;

  const SourceConfig({
    required this.id,
    required this.kind,
    required this.label,
    required this.fields,
  });

  Source build() {
    switch (kind) {
      case SourceKind.stalker:
        return StalkerSource(portal: fields['portal']!, mac: fields['mac']!);
      case SourceKind.xtream:
        return XtreamSource(
          host: fields['host']!,
          username: fields['username']!,
          password: fields['password']!,
        );
      case SourceKind.m3u:
        return M3uSource(
          playlistUrl: fields['playlistUrl']!,
          epgUrl: _opt('epgUrl'),
          userAgent: _opt('userAgent'),
        );
      case SourceKind.demo:
        return DemoSource();
    }
  }

  String? _opt(String key) {
    final v = fields[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'label': label,
        'fields': fields,
      };

  factory SourceConfig.fromJson(Map<String, dynamic> j) => SourceConfig(
        id: j['id'] as String,
        kind: SourceKind.values.byName(j['kind'] as String),
        label: j['label'] as String,
        fields: Map<String, String>.from(j['fields'] as Map),
      );
}