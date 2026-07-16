import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_sync.dart';

void main() {
  test('cloud overwrite warning is quiet when there are no local changes', () {
    expect(
      shouldWarnBeforeOverwrite(
        knownRemoteRevision: DateTime.utc(2024),
        currentRemoteRevision: DateTime.utc(2025),
        hasLocalChanges: false,
      ),
      isFalse,
    );
  });

  test('warns when the server revision advanced after the local snapshot', () {
    expect(
      shouldWarnBeforeOverwrite(
        knownRemoteRevision: DateTime.utc(2024),
        currentRemoteRevision: DateTime.utc(2024, 1, 1, 0, 0, 1),
        hasLocalChanges: true,
      ),
      isTrue,
    );
  });

  test('warns conservatively when either revision is unavailable', () {
    expect(
      shouldWarnBeforeOverwrite(
        knownRemoteRevision: null,
        currentRemoteRevision: DateTime.utc(2024),
        hasLocalChanges: true,
      ),
      isTrue,
    );
  });
}
