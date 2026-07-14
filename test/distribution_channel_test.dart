import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/distribution_channel.dart';

void main() {
  test('unknown or missing build channel fails to development mode', () {
    expect(parseDistributionChannel(''), DistributionChannel.development);
    expect(parseDistributionChannel('typo'), DistributionChannel.development);
  });

  test('only GitHub-direct builds own the in-app updater', () {
    expect(DistributionChannel.githubDirect.ownsDirectUpdates, isTrue);
    expect(DistributionChannel.development.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.googlePlay.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.microsoftStore.ownsDirectUpdates, isFalse);
  });

  test('both Store channels are Store-managed', () {
    expect(DistributionChannel.googlePlay.isStoreManaged, isTrue);
    expect(DistributionChannel.microsoftStore.isStoreManaged, isTrue);
    expect(DistributionChannel.githubDirect.isStoreManaged, isFalse);
  });

  test('update track parser is fail-safe stable', () {
    expect(parseUpdateTrack(null), UpdateTrack.stable);
    expect(parseUpdateTrack('unknown'), UpdateTrack.stable);
    expect(parseUpdateTrack('beta'), UpdateTrack.beta);
  });
}
