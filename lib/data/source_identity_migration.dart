import '../sources/source_config.dart';
import 'app_database.dart';

/// Moves pre-PR4 cache/user-state keys to the stable source and channel
/// identities before a [Source] can publish rows under those identities.
Future<void> migrateSourceIdentity(AppDatabase db, SourceConfig config) async {
  await db.migrateSourceNamespace(config.legacyCacheId, config.id);
  if (config.kind == SourceKind.m3u) {
    await db.migrateM3uChannelIds(config.id);
  }
}

Future<void> migrateAllSourceIdentities(
  AppDatabase db,
  Iterable<SourceConfig> configs,
) async {
  for (final config in configs) {
    await migrateSourceIdentity(db, config);
  }
}
