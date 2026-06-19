class MetadataConfig {
  final String tmdbApiKey;
  final bool autoEnrich;

  const MetadataConfig({this.tmdbApiKey = '', this.autoEnrich = true});

  String get normalizedTmdbCredential => normalizeTmdbCredential(tmdbApiKey);

  bool get hasTmdb => normalizedTmdbCredential.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'tmdbApiKey': normalizedTmdbCredential,
    'autoEnrich': autoEnrich,
  };

  factory MetadataConfig.fromJson(Map<String, dynamic> json) => MetadataConfig(
    tmdbApiKey: normalizeTmdbCredential(json['tmdbApiKey'] as String?),
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
