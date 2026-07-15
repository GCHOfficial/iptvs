import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/update_manifest.dart';
import 'package:iptvs/data/update_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('pending Android update survives a store recreation', () async {
    const store = UpdateStore();
    final pending = PendingUpdate(
      version: '1.2.3',
      path: '/cache/iptvs-1.2.3-android.apk',
      releasePage: Uri.parse(
        'https://github.com/GCHOfficial/iptvs/releases/tag/v1.2.3',
      ),
      artifact: ReleaseArtifact(
        platform: 'android',
        filename: 'iptvs-1.2.3-android.apk',
        byteSize: 123,
        sha256: List.filled(64, 'a').join(),
      ),
    );

    await store.setPendingUpdate(pending);
    final restored = await const UpdateStore().pendingUpdate();

    expect(restored?.version, '1.2.3');
    expect(restored?.path, pending.path);
    expect(restored?.releasePage, pending.releasePage);
    expect(restored?.artifact.filename, pending.artifact.filename);
    expect(restored?.artifact.byteSize, 123);
    expect(restored?.artifact.sha256, pending.artifact.sha256);
  });

  test('malformed pending state fails closed and is removed', () async {
    FlutterSecureStorage.setMockInitialValues({
      'update_pending_install': '{"version":"bad","path":"/tmp/x"}',
    });
    const store = UpdateStore();

    expect(await store.pendingUpdate(), isNull);
    expect(await store.pendingUpdate(), isNull);
  });

  test('pending state can be cleared after a successful upgrade', () async {
    const store = UpdateStore();
    await store.setPendingUpdate(
      PendingUpdate(
        version: '1.2.3',
        path: '/cache/iptvs-1.2.3-android.apk',
        releasePage: Uri.parse('https://github.com/GCHOfficial/iptvs/releases'),
        artifact: ReleaseArtifact(
          platform: 'android',
          filename: 'iptvs-1.2.3-android.apk',
          byteSize: 1,
          sha256: List.filled(64, 'b').join(),
        ),
      ),
    );

    await store.clearPendingUpdate();
    expect(await store.pendingUpdate(), isNull);
  });
}
