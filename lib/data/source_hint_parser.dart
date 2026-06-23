import '../sources/source.dart';

enum SourceHintConfidence { strong, weak }

class SourceHint {
  final String label;
  final SourceHintConfidence confidence;

  const SourceHint(this.label, this.confidence);
}

String? providerSourceTitle(MediaItem item) {
  final value =
      item.extra['providerTitle'] ??
      item.extra['sourceTitle'] ??
      item.extra['name'] ??
      item.extra['title'];
  final text = value?.toString().trim();
  if (text == null || text.isEmpty || text == item.title) return null;
  return text;
}

List<String> sourceHintLabels(MediaItem item, {bool includeWeak = false}) =>
    sourceHints(item)
        .where(
          (hint) =>
              includeWeak || hint.confidence == SourceHintConfidence.strong,
        )
        .map((hint) => hint.label)
        .toList();

List<SourceHint> sourceHints(MediaItem item) {
  final providerTitle = providerSourceTitle(item);
  final explicitFields = [
    item.extra['audio_language'],
    item.extra['audio_lang'],
    item.extra['language'],
    item.extra['lang'],
    item.extra['subtitle_language'],
    item.extra['subtitles'],
  ].whereType<Object>().map((v) => v.toString()).join(' ');
  final markerFields = <String>[];
  if (providerTitle != null) {
    markerFields.addAll(
      RegExp(
        r'[\[(]([^\])]+)[\])]',
      ).allMatches(providerTitle).map((m) => m.group(1) ?? ''),
    );
    final pipe = providerTitle.indexOf('|');
    if (pipe > 0 && pipe <= 24) {
      markerFields.add(providerTitle.substring(0, pipe));
    }
    final dash = providerTitle.indexOf(' - ');
    if (dash > 0 && dash <= 24) {
      markerFields.add(providerTitle.substring(0, dash));
    }
  }
  final fields = '$explicitFields ${markerFields.join(' ')}';
  if (fields.trim().isEmpty) return const [];
  final text = fields.toUpperCase();
  final hints = <SourceHint>[];

  void addLabel(
    String label, {
    SourceHintConfidence confidence = SourceHintConfidence.strong,
  }) {
    if (!hints.any((hint) => hint.label == label)) {
      hints.add(SourceHint(label, confidence));
    }
  }

  bool has(Pattern pattern) => pattern.allMatches(text).isNotEmpty;

  final hasMulti = has(RegExp(r'\b(MULTI|MULTIAUDIO|MULTI-AUDIO)\b'));
  final hasDual = has(RegExp(r'\b(DUAL|DUALAUDIO|DUAL-AUDIO)\b'));
  final hasDub = has(RegExp(r'\b(DUB|DUBBED|DUBLAT|DUBLADO)\b'));
  final hasSub = has(
    RegExp(r'\b(SUB|SUBS|SUBBED|SUBTITLE|SUBTITLES|VOST|VOSTFR|VOSE)\b'),
  );
  final hasAudio = has(
    RegExp(r'\b(AUDIO|AUD|DUB|DUBBED|DUAL|MULTI|MULTIAUDIO|MULTI-AUDIO)\b'),
  );

  if (hasMulti) addLabel('Multi audio');
  if (hasDual) addLabel('Dual audio');
  if (hasDub) addLabel('Dubbed');

  final tokens = _sourceHintTokens(fields);
  final aliasOwners = <String, Set<String>>{};
  for (final entry in _languages.entries) {
    for (final alias in [...entry.value.strong, ...entry.value.weak]) {
      aliasOwners.putIfAbsent(alias, () => <String>{}).add(entry.key);
    }
  }
  final matchedLanguages =
      <({String language, SourceHintConfidence confidence})>[];
  for (final entry in _languages.entries) {
    final strong = entry.value.strong.any(
      (alias) => tokens.contains(alias) && aliasOwners[alias]?.length == 1,
    );
    final weak = entry.value.weak.any(
      (alias) => tokens.contains(alias) && aliasOwners[alias]?.length == 1,
    );
    if (strong) {
      matchedLanguages.add((
        language: entry.key,
        confidence: SourceHintConfidence.strong,
      ));
    } else if (weak && (hasAudio || hasDub || hasDual || hasMulti || hasSub)) {
      matchedLanguages.add((
        language: entry.key,
        confidence: SourceHintConfidence.weak,
      ));
    }
  }
  if (matchedLanguages.isEmpty && hasSub) addLabel('Subtitles');
  for (final match in matchedLanguages.take(3)) {
    final language = match.language;
    if (hasSub && !hasAudio) {
      addLabel('Subs: $language', confidence: match.confidence);
    } else if (hasAudio || hasDub || hasDual || hasMulti) {
      addLabel('Audio: $language', confidence: match.confidence);
      if (hasSub) addLabel('Subs: $language', confidence: match.confidence);
    } else {
      addLabel(language, confidence: match.confidence);
    }
  }
  return hints;
}

Set<String> _sourceHintTokens(String fields) {
  final tokens = <String>{};
  for (final match in RegExp(r'[A-Z0-9]+').allMatches(fields.toUpperCase())) {
    final token = match.group(0);
    if (token != null && token.isNotEmpty) tokens.add(token);
  }
  return tokens;
}

class _LanguageAliases {
  final List<String> strong;
  final List<String> weak;

  const _LanguageAliases({required this.strong, this.weak = const []});
}

const _languages = {
  'Albanian': _LanguageAliases(strong: ['SQ', 'ALB', 'ALBANIAN'], weak: ['AL']),
  'Arabic': _LanguageAliases(
    strong: ['AR', 'ARA', 'ARABIC'],
    weak: [
      'AE',
      'BH',
      'DZ',
      'EG',
      'IQ',
      'JO',
      'KW',
      'LB',
      'LY',
      'MA',
      'OM',
      'QA',
      'SA',
      'SY',
      'TN',
      'YE',
    ],
  ),
  'Armenian': _LanguageAliases(
    strong: ['HY', 'ARM', 'HYE', 'ARMENIAN'],
    weak: ['AM'],
  ),
  'Azerbaijani': _LanguageAliases(
    strong: ['AZE', 'AZERI', 'AZERBAIJANI'],
    weak: ['AZ'],
  ),
  'Belarusian': _LanguageAliases(
    strong: ['BEL', 'BELARUSIAN'],
    weak: ['BY', 'BE'],
  ),
  'Bosnian': _LanguageAliases(strong: ['BS', 'BOS', 'BOSNIAN'], weak: ['BA']),
  'Bulgarian': _LanguageAliases(strong: ['BG', 'BUL', 'BULGARIAN']),
  'Chinese': _LanguageAliases(
    strong: ['ZH', 'CHI', 'ZHO', 'CHINESE', 'MANDARIN'],
    weak: ['CN'],
  ),
  'Croatian': _LanguageAliases(
    strong: ['HRV', 'CROATIAN'],
    weak: ['HR', 'HRT'],
  ),
  'Czech': _LanguageAliases(
    strong: ['CS', 'CES', 'CZE', 'CZECH'],
    weak: ['CZ'],
  ),
  'Danish': _LanguageAliases(strong: ['DA', 'DAN', 'DANISH'], weak: ['DK']),
  'Dutch': _LanguageAliases(strong: ['NL', 'DUT', 'NLD', 'DUTCH']),
  'English': _LanguageAliases(
    strong: ['EN', 'ENG', 'ENGLISH'],
    weak: ['UK', 'GB', 'US', 'USA'],
  ),
  'Estonian': _LanguageAliases(strong: ['ET', 'EST', 'ESTONIAN'], weak: ['EE']),
  'Finnish': _LanguageAliases(strong: ['FI', 'FIN', 'FINNISH']),
  'French': _LanguageAliases(
    strong: ['FR', 'FRE', 'FRA', 'FRENCH', 'TRUEFRENCH', 'VOSTFR'],
    weak: ['BE', 'CA', 'CH'],
  ),
  'Georgian': _LanguageAliases(
    strong: ['KA', 'GEO', 'KAT', 'GEORGIAN'],
    weak: ['GE'],
  ),
  'German': _LanguageAliases(
    strong: ['DE', 'GER', 'DEU', 'GERMAN'],
    weak: ['AT'],
  ),
  'Greek': _LanguageAliases(
    strong: ['EL', 'ELL', 'GRE', 'GREEK'],
    weak: ['GR'],
  ),
  'Hebrew': _LanguageAliases(strong: ['HE', 'HEB', 'HEBREW'], weak: ['IL']),
  'Hindi': _LanguageAliases(strong: ['HI', 'HIN', 'HINDI'], weak: ['IN']),
  'Hungarian': _LanguageAliases(strong: ['HU', 'HUN', 'HUNGARIAN']),
  'Indonesian': _LanguageAliases(strong: ['IND', 'INDONESIAN'], weak: ['ID']),
  'Italian': _LanguageAliases(strong: ['IT', 'ITA', 'ITALIAN']),
  'Japanese': _LanguageAliases(strong: ['JA', 'JPN', 'JAPANESE'], weak: ['JP']),
  'Kazakh': _LanguageAliases(strong: ['KK', 'KAZ', 'KAZAKH'], weak: ['KZ']),
  'Korean': _LanguageAliases(strong: ['KO', 'KOR', 'KOREAN'], weak: ['KR']),
  'Latvian': _LanguageAliases(strong: ['LV', 'LAV', 'LATVIAN']),
  'Lithuanian': _LanguageAliases(strong: ['LT', 'LIT', 'LITHUANIAN']),
  'Macedonian': _LanguageAliases(strong: ['MKD', 'MACEDONIAN'], weak: ['MK']),
  'Malay': _LanguageAliases(
    strong: ['MS', 'MAY', 'MSA', 'MALAY'],
    weak: ['MY'],
  ),
  'Norwegian': _LanguageAliases(strong: ['NO', 'NOR', 'NORWEGIAN']),
  'Persian': _LanguageAliases(
    strong: ['FA', 'PER', 'FAS', 'PERSIAN', 'FARSI', 'IR'],
  ),
  'Polish': _LanguageAliases(strong: ['PL', 'POL', 'POLISH']),
  'Portuguese': _LanguageAliases(
    strong: ['PT', 'POR', 'PORTUGUESE'],
    weak: ['BR', 'BRA', 'BRASIL'],
  ),
  'Romanian': _LanguageAliases(
    strong: ['RO', 'ROM', 'RON', 'RUM', 'ROMANIAN', 'ROMANA'],
    weak: ['MD'],
  ),
  'Russian': _LanguageAliases(strong: ['RU', 'RUS', 'RUSSIAN']),
  'Serbian': _LanguageAliases(strong: ['SR', 'SRP', 'SERBIAN'], weak: ['RS']),
  'Seychellois Creole': _LanguageAliases(
    strong: ['CRS', 'SEYCHELLOIS'],
    weak: ['SC'],
  ),
  'Slovak': _LanguageAliases(strong: ['SK', 'SLK', 'SLO', 'SLOVAK']),
  'Slovenian': _LanguageAliases(strong: ['SI', 'SL', 'SLV', 'SLOVENIAN']),
  'Spanish': _LanguageAliases(
    strong: ['ES', 'ESP', 'SPA', 'SPANISH', 'CASTELLANO', 'LATINO'],
    weak: ['MX', 'CL', 'CO', 'PE'],
  ),
  'Swedish': _LanguageAliases(strong: ['SV', 'SWE', 'SWEDISH'], weak: ['SE']),
  'Tajik': _LanguageAliases(strong: ['TG', 'TGK', 'TAJIK'], weak: ['TJ']),
  'Thai': _LanguageAliases(strong: ['TH', 'THA', 'THAI']),
  'Turkish': _LanguageAliases(strong: ['TR', 'TUR', 'TURKISH']),
  'Turkmen': _LanguageAliases(strong: ['TM', 'TK', 'TUK', 'TURKMEN']),
  'Ukrainian': _LanguageAliases(
    strong: ['UKR', 'UA', 'UKRAINIAN'],
    weak: ['UK'],
  ),
  'Urdu': _LanguageAliases(strong: ['UR', 'URD', 'URDU'], weak: ['PK']),
  'Uzbek': _LanguageAliases(strong: ['UZ', 'UZB', 'UZBEK']),
  'Vietnamese': _LanguageAliases(
    strong: ['VI', 'VIE', 'VIETNAMESE'],
    weak: ['VN'],
  ),
};
