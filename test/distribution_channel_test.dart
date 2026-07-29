import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/distribution_channel.dart';

void main() {
  test('unknown or missing build channel fails to development mode', () {
    expect(parseDistributionChannel(''), DistributionChannel.development);
    expect(parseDistributionChannel('typo'), DistributionChannel.development);
  });

  test('altStore parses from its exact string', () {
    expect(parseDistributionChannel('altStore'), DistributionChannel.altStore);
  });

  test('only GitHub-direct builds own the in-app updater', () {
    expect(DistributionChannel.githubDirect.ownsDirectUpdates, isTrue);
    expect(DistributionChannel.development.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.googlePlay.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.microsoftStore.ownsDirectUpdates, isFalse);
    expect(DistributionChannel.altStore.ownsDirectUpdates, isFalse);
  });

  test('both Store channels are Store-managed; altStore is not', () {
    expect(DistributionChannel.googlePlay.isStoreManaged, isTrue);
    expect(DistributionChannel.microsoftStore.isStoreManaged, isTrue);
    expect(DistributionChannel.githubDirect.isStoreManaged, isFalse);
    expect(DistributionChannel.altStore.isStoreManaged, isFalse);
  });

  test('altStore display name', () {
    expect(DistributionChannel.altStore.displayName, 'AltStore');
  });

  test('update track parser is fail-safe stable', () {
    expect(parseUpdateTrack(null), UpdateTrack.stable);
    expect(parseUpdateTrack('unknown'), UpdateTrack.stable);
    expect(parseUpdateTrack('beta'), UpdateTrack.beta);
  });
}
