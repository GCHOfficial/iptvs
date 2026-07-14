/// Who packaged the running build and therefore owns its update lifecycle.
enum DistributionChannel {
  development,
  githubDirect,
  googlePlay,
  microsoftStore,
}

DistributionChannel parseDistributionChannel(String value) {
  return switch (value.trim()) {
    'githubDirect' => DistributionChannel.githubDirect,
    'googlePlay' => DistributionChannel.googlePlay,
    'microsoftStore' => DistributionChannel.microsoftStore,
    _ => DistributionChannel.development,
  };
}

extension DistributionChannelPolicy on DistributionChannel {
  bool get ownsDirectUpdates => this == DistributionChannel.githubDirect;

  bool get isStoreManaged =>
      this == DistributionChannel.googlePlay ||
      this == DistributionChannel.microsoftStore;

  String get displayName => switch (this) {
    DistributionChannel.development => 'Development',
    DistributionChannel.githubDirect => 'GitHub direct',
    DistributionChannel.googlePlay => 'Google Play',
    DistributionChannel.microsoftStore => 'Microsoft Store',
  };
}

class DistributionConfig {
  const DistributionConfig._();

  static const rawChannel = String.fromEnvironment(
    'DISTRIBUTION_CHANNEL',
    defaultValue: 'development',
  );

  static final channel = parseDistributionChannel(rawChannel);

  static bool get directUpdaterEnabled => channel.ownsDirectUpdates;
}

/// GitHub-direct users may opt into signed prereleases. Store builds use Play
/// testing tracks or Partner Center package flights instead.
enum UpdateTrack { stable, beta }

UpdateTrack parseUpdateTrack(String? value) =>
    value == 'beta' ? UpdateTrack.beta : UpdateTrack.stable;

extension UpdateTrackLabel on UpdateTrack {
  String get storageValue => name;
  String get displayName => this == UpdateTrack.beta ? 'Beta' : 'Stable';
}
