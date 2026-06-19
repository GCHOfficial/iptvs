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

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'tmdbApiKey': normalizedTmdbCredential,
    'tvdbApiKey': tvdbApiKey.trim(),
    'tvdbPin': tvdbPin.trim(),
    'mdblistApiKey': mdblistApiKey.trim(),
    'autoEnrich': autoEnrich,
  };

  factory MetadataConfig.fromJson(Map<String, dynamic> json) => MetadataConfig(
    provider: json['provider'] as String? ?? 'tmdb',
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
}
