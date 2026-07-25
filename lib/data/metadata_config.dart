class MetadataConfig {
  final String provider;
  final String tmdbApiKey;
  final String tvdbApiKey;
  final String tvdbPin;
  final String mdblistApiKey;
  final bool autoEnrich;

  const MetadataConfig({
    this.provider = 'tmdb',
    this.tmdbApiKey = '',
    this.tvdbApiKey = '',
    this.tvdbPin = '',
    this.mdblistApiKey = '',
    this.autoEnrich = true,
  });

  String get normalizedTmdbCredential => normalizeTmdbCredential(tmdbApiKey);

  bool get hasTmdb => normalizedTmdbCredential.isNotEmpty;
  bool get hasTvdb => tvdbApiKey.trim().isNotEmpty;
  bool get hasMdblist => mdblistApiKey.trim().isNotEmpty;

  String get preferredVisualProvider =>
      provider == 'tvdb' || provider == 'tmdb' ? provider : 'tmdb';

  // Cloud sync's Phase-2 split: [toJson] stays the FULL config (used for local
  // keychain persistence via SourceStore). For the cloud boundary, only the
  // broad keys ride the `metadata_configs` row ([cloudBroadJson]) and the API
  // keys/PIN travel through the dedicated secret RPC ([cloudSecretFields]),
  // encrypted client-side when the profile has opt-in E2EE. See
  // docs/cloud-sync.md and lib/data/secret_keys.dart.

  /// The broad (non-secret) projection stored on the cloud `metadata_configs`
  /// row: the provider choice and the auto-enrich flag, never an API key.
  Map<String, dynamic> cloudBroadJson() => {
    'provider': preferredVisualProvider,
    'autoEnrich': autoEnrich,
  };

  /// The secret projection (API keys / PIN), non-empty entries only, that
  /// travels through the metadata secret RPC. Empty when the device holds no
  /// keys (so a push preserves whatever the server has rather than blanking it).
  Map<String, String> cloudSecretFields() {
    final out = <String, String>{};
    if (normalizedTmdbCredential.isNotEmpty) {
      out['tmdbApiKey'] = normalizedTmdbCredential;
    }
    if (tvdbApiKey.trim().isNotEmpty) out['tvdbApiKey'] = tvdbApiKey.trim();
    if (tvdbPin.trim().isNotEmpty) out['tvdbPin'] = tvdbPin.trim();
    if (mdblistApiKey.trim().isNotEmpty) {
      out['mdblistApiKey'] = mdblistApiKey.trim();
    }
    return out;
  }

  /// Rebuild a config from a pulled cloud row: broad keys from [broad], API keys
  /// from the decrypted [secret] map, with a defensive fallback to the device's
  /// existing [local] value for any secret the cloud left absent (amendment B1 —
  /// cloud non-empty wins, local only fills gaps, so a locked/partial profile
  /// never blanks a key this device already holds).
  factory MetadataConfig.fromCloudParts({
    required Map<String, dynamic> broad,
    required Map<String, String> secret,
    required MetadataConfig local,
  }) {
    String pick(String key, String localValue) {
      final v = secret[key];
      return (v != null && v.isNotEmpty) ? v : localValue;
    }

    return MetadataConfig(
      provider: _normalizeProvider(broad['provider'] as String?),
      tmdbApiKey: pick('tmdbApiKey', local.tmdbApiKey),
      tvdbApiKey: pick('tvdbApiKey', local.tvdbApiKey),
      tvdbPin: pick('tvdbPin', local.tvdbPin),
      mdblistApiKey: pick('mdblistApiKey', local.mdblistApiKey),
      autoEnrich: broad['autoEnrich'] as bool? ?? local.autoEnrich,
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': preferredVisualProvider,
    'tmdbApiKey': normalizedTmdbCredential,
    'tvdbApiKey': tvdbApiKey.trim(),
    'tvdbPin': tvdbPin.trim(),
    'mdblistApiKey': mdblistApiKey.trim(),
    'autoEnrich': autoEnrich,
  };

  factory MetadataConfig.fromJson(Map<String, dynamic> json) => MetadataConfig(
    provider: _normalizeProvider(json['provider'] as String?),
    tmdbApiKey: normalizeTmdbCredential(json['tmdbApiKey'] as String?),
    tvdbApiKey: (json['tvdbApiKey'] as String? ?? '').trim(),
    tvdbPin: (json['tvdbPin'] as String? ?? '').trim(),
    mdblistApiKey: (json['mdblistApiKey'] as String? ?? '').trim(),
    autoEnrich: json['autoEnrich'] as bool? ?? true,
  );

  static String normalizeTmdbCredential(String? value) {
    final raw = (value ?? '').trim();
    if (raw.toLowerCase().startsWith('bearer ')) {
      return raw.substring(7).trim();
    }
    return raw;
  }

  static String _normalizeProvider(String? value) =>
      value == 'tvdb' ? 'tvdb' : 'tmdb';
}
