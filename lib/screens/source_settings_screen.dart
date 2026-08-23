import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/net.dart' show looksLikeValidUrl;
import '../data/source_store.dart';
import '../sources/epg_guides.dart' show kMaxEpgGuides;
import '../sources/m3u_upgrade.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../sources/xtream_source.dart' show kXtreamStreamExtensions;
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';

/// A category as this screen renders it, regardless of which kind it came
/// from — the three provider lists have different element types but identical
/// needs here.
typedef CategoryEntry = ({String id, String title});

/// The next hidden-category set when bulk-toggling [affected]: [hide] true adds
/// them all (union), false reveals them (difference). Pure so the bulk Show
/// all / Hide all controls — which operate on the *filtered* subset and must
/// leave off-screen categories untouched — stay unit-testable.
Set<String> bulkToggleHidden(
  Set<String> current,
  Iterable<String> affected, {
  required bool hide,
}) {
  final next = current.toSet();
  if (hide) {
    next.addAll(affected);
  } else {
    next.removeAll(affected);
  }
  return next;
}

/// The next value in the [_StreamFormatTile] cycle: unset (platform default)
/// → `ts` → `m3u8` → unset. Pure so the tri-state cycle stays unit-testable;
/// [current] outside `{null, 'ts', 'm3u8'}` (including a value this screen
/// never wrote) is treated as unset, matching
/// `resolveXtreamStreamExtension`'s own fallback.
String? nextStreamExtension(String? current) {
  const order = <String?>[null, 'ts', 'm3u8'];
  final idx = order.indexOf(current);
  return order[((idx < 0 ? 0 : idx) + 1) % order.length];
}

/// Per-source preferences. The first capability is enabling/disabling
/// categories: a disabled category (and everything in it) is hidden from
/// browsing for this source. Reads the source's cached category lists so it
/// works without rebuilding a live [Source]; persists toggles onto
/// [SourceConfig.settings] via the [SourceStore].
class SourceSettingsScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;
  final SourceConfig config;

  const SourceSettingsScreen({
    super.key,
    required this.store,
    required this.db,
    required this.config,
  });

  @override
  State<SourceSettingsScreen> createState() => _SourceSettingsScreenState();
}

class _SourceSettingsScreenState extends State<SourceSettingsScreen> {
  late SourceConfig _config = widget.config;

  /// Every category, per kind, as a uniform (id, title) list.
  ///
  /// Materialised once per [_load] rather than derived per call. It used to be
  /// three typed lists mapped and copied inside [_all] on every invocation,
  /// and [_filtered], [_hasAnyMatch] and each section header all called that —
  /// so a provider's whole category list was copied roughly eight times per
  /// build, and a build happens on every keystroke and every toggle.
  Map<ContentKind, List<CategoryEntry>> _allByKind = const {};
  bool _loading = true;

  final TextEditingController _searchController = TextEditingController();
  late final TextEditingController _catchupTimezoneController =
      TextEditingController(
        text: _config.settings['catchupTimezone']?.toString() ?? '',
      );
  late final TextEditingController _catchupOffsetController =
      TextEditingController(
        text: _config.settings['catchupOffsetMinutes']?.toString() ?? '',
      );
  late final TextEditingController _catchupDaysController =
      TextEditingController(
        text: _config.settings['catchupMaxDays']?.toString() ?? '',
      );
  String _query = '';
  String? _catchupError;
  String? _epgError;
  bool _upgrading = false;

  /// One controller per extra guide URL, in priority order.
  ///
  /// Seeded from the stored field and thereafter the source of truth for the
  /// editor — rows are added and removed here, and only [_saveEpgGuides] writes
  /// back. Kept as a growable list of controllers rather than a list of strings
  /// so a row keeps its cursor and composing state while its neighbours change.
  late final List<TextEditingController> _epgControllers = [
    for (final url in _config.extraEpgUrls) TextEditingController(text: url),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _catchupTimezoneController.dispose();
    _catchupOffsetController.dispose();
    _catchupDaysController.dispose();
    for (final c in _epgControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    // The cache is keyed by the stable SourceConfig UUID exposed as Source.id.
    // Resolve it through the built source so this screen stays provider-neutral.
    final source = _config.build();
    final sourceId = source.id;
    await source.dispose();
    final live = await widget.db.readCategories(sourceId);
    final movies = await widget.db.readMediaCategories(
      sourceId,
      ContentKind.movie,
    );
    final series = await widget.db.readMediaCategories(
      sourceId,
      ContentKind.series,
    );
    if (!mounted) return;
    setState(() {
      _allByKind = {
        ContentKind.live: [for (final c in live) (id: c.id, title: c.title)],
        ContentKind.movie: [for (final c in movies) (id: c.id, title: c.title)],
        ContentKind.series: [
          for (final c in series) (id: c.id, title: c.title),
        ],
      };
      // The filtered lists are derived from what just changed.
      _filteredCacheQuery = null;
      _loading = false;
    });
  }

  /// All categories for [kind] as a uniform (id, title) list.
  List<CategoryEntry> _all(ContentKind kind) => _allByKind[kind] ?? const [];

  /// The query the cached filter results below were computed for, or null when
  /// they must be recomputed ([_load] replaced the categories).
  String? _filteredCacheQuery;
  Map<ContentKind, List<CategoryEntry>> _filteredCache = const {};

  /// [kind]'s categories matching the current search query.
  ///
  /// Cached on the query, so a *toggle* — which rebuilds but changes no
  /// filtering input — doesn't re-scan every category title of every kind.
  List<CategoryEntry> _filtered(ContentKind kind) {
    final q = _query.trim().toLowerCase();
    if (_filteredCacheQuery != q) {
      _filteredCacheQuery = q;
      _filteredCache = {
        for (final k in const [
          ContentKind.live,
          ContentKind.movie,
          ContentKind.series,
        ])
          k: q.isEmpty
              ? _all(k)
              : _all(
                  k,
                ).where((c) => c.title.toLowerCase().contains(q)).toList(),
      };
    }
    return _filteredCache[kind] ?? const [];
  }

  Future<void> _save(SourceConfig next) async {
    setState(() => _config = next);
    await widget.store.save(next);
  }

  Future<void> _toggle(ContentKind kind, String categoryId) async {
    final hidden = _config.hiddenCategoryIds(kind).toSet();
    if (!hidden.add(categoryId)) hidden.remove(categoryId);
    await _save(_config.withHiddenCategories(kind, hidden));
  }

  /// Show/Hide every currently-visible (filtered) category of [kind]. Off-screen
  /// categories keep their state (the helper merges rather than replaces).
  Future<void> _bulkSection(ContentKind kind, {required bool hide}) async {
    final ids = _filtered(kind).map((c) => c.id);
    final next = bulkToggleHidden(
      _config.hiddenCategoryIds(kind),
      ids,
      hide: hide,
    );
    await _save(_config.withHiddenCategories(kind, next));
  }

  /// Show/Hide the filtered categories across all three kinds in one save.
  Future<void> _bulkAll({required bool hide}) async {
    var next = _config;
    for (final kind in ContentKind.values) {
      final ids = _filtered(kind).map((c) => c.id);
      next = next.withHiddenCategories(
        kind,
        bulkToggleHidden(next.hiddenCategoryIds(kind), ids, hide: hide),
      );
    }
    await _save(next);
  }

  /// The guide this source already has without any user configuration, named
  /// for the read-only first row of the editor. Null when there is none, which
  /// is an M3U playlist carrying neither an explicit EPG URL nor a `url-tvg`
  /// header — there, a user-added guide is the *only* guide.
  String? get _builtInGuideLabel => switch (_config.kind) {
    SourceKind.xtream => "The panel's own guide (xmltv.php)",
    SourceKind.stalker => 'The portal\'s own guide',
    SourceKind.m3u =>
      (_config.fields['epgUrl'] ?? '').isNotEmpty
          ? 'The EPG URL set on this source'
          : "The playlist's own url-tvg guide, if it has one",
    SourceKind.demo => null,
  };

  void _addEpgGuide() {
    setState(() => _epgControllers.add(TextEditingController()));
  }

  void _removeEpgGuide(int index) {
    setState(() => _epgControllers.removeAt(index).dispose());
  }

  Future<void> _saveEpgGuides() async {
    final urls = <String>[];
    for (final controller in _epgControllers) {
      final url = controller.text.trim();
      if (url.isEmpty) continue; // a blank row is "not filled in yet"
      if (!looksLikeValidUrl(url, requireScheme: true)) {
        setState(
          () => _epgError =
              'Enter a valid URL starting with http:// or https://',
        );
        return;
      }
      // A duplicate would be silently dropped by the merge anyway (the second
      // copy finds every channel already claimed), so say so rather than
      // letting the user think it did something.
      if (urls.contains(url)) {
        setState(() => _epgError = 'That guide is already in the list.');
        return;
      }
      urls.add(url);
    }
    final fields = <String, String>{..._config.fields};
    if (urls.isEmpty) {
      fields.remove('epgUrls');
    } else {
      fields['epgUrls'] = urls.join('\n');
    }
    await _save(_config.copyWith(fields: fields));
    // Without this the new guide is invisible for up to `_epgMaxAge` — the
    // refresh is skipped while the cached guide is still young, which is right
    // for a periodic refresh and wrong when the set of guides just changed.
    await widget.db.invalidateEpg(_config.id);
    if (!mounted) return;
    setState(() => _epgError = null);
    ScaffoldMessenger.of(context).showSnackBar(
      // Honest about the timing: the running `Source` still holds the old URL
      // list, so the guides take effect when the source is next built — the
      // same "applies on next load" contract the catch-up overrides above have.
      const SnackBar(content: Text('EPG guides saved — applied on next reload')),
    );
  }

  Future<void> _saveCatchupOverrides() async {
    final timezone = _catchupTimezoneController.text.trim();
    final offsetText = _catchupOffsetController.text.trim();
    final daysText = _catchupDaysController.text.trim();
    final offset = offsetText.isEmpty ? null : int.tryParse(offsetText);
    final days = daysText.isEmpty ? null : int.tryParse(daysText);
    String? error;
    if (!isSupportedCatchupTimezone(timezone)) {
      error =
          'Use an IANA timezone such as Europe/London, UTC, or a fixed offset.';
    } else if (offsetText.isNotEmpty &&
        (offset == null || offset < -14 * 60 || offset > 14 * 60)) {
      error = 'Fixed offset must be minutes between -840 and 840.';
    } else if (daysText.isNotEmpty &&
        (days == null || days <= 0 || days > 365)) {
      error = 'Archive window must be between 1 and 365 days.';
    }
    if (error != null) {
      setState(() => _catchupError = error);
      return;
    }
    final settings = <String, dynamic>{..._config.settings}
      ..remove('catchupTimezone')
      ..remove('catchupOffsetMinutes')
      ..remove('catchupMaxDays');
    if (timezone.isNotEmpty) settings['catchupTimezone'] = timezone;
    if (offset != null) settings['catchupOffsetMinutes'] = offset;
    if (days != null) settings['catchupMaxDays'] = days;
    await _save(_config.copyWith(settings: settings));
    if (!mounted) return;
    setState(() => _catchupError = null);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Catch-up overrides saved')));
  }

  /// The explicit override, or `null` for "unset" (platform default). Any
  /// stored value outside [kXtreamStreamExtensions] — including one this
  /// screen never wrote — is treated as unset too, matching
  /// `resolveXtreamStreamExtension`'s own fallback.
  String? get _streamExtension {
    final v = _config.settings['streamExtension']?.toString();
    return kXtreamStreamExtensions.contains(v) ? v : null;
  }

  /// Cycles Automatic → .ts → .m3u8 → Automatic. Only ever called from a user
  /// tap, so opening this screen never writes a value that pins a source away
  /// from tracking the platform default.
  Future<void> _cycleStreamExtension() async {
    final next = nextStreamExtension(_streamExtension);
    final settings = <String, dynamic>{..._config.settings};
    if (next == null) {
      settings.remove('streamExtension');
    } else {
      settings['streamExtension'] = next;
    }
    await _save(_config.copyWith(settings: settings));
  }

  /// Converts this M3U source into a real Xtream one, after the panel proves
  /// it is one.
  ///
  /// The probe is the whole point: the panel URL *shape* is only a guess (some
  /// resellers serve `get.php` and no `player_api.php` at all), and this
  /// rewrites a saved source — so it converts on a real authentication or not
  /// at all. That verification is also why the offer lives here rather than in
  /// the web panel, which can't reach a provider from a browser.
  Future<void> _upgradeToXtream() async {
    if (_upgrading) return;
    setState(() => _upgrading = true);
    SourceConfig? upgraded;
    try {
      upgraded = await upgradeM3uToXtream(_config);
    } finally {
      if (mounted) setState(() => _upgrading = false);
    }
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (upgraded == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't reach an Xtream panel at that address — the source is "
            'unchanged.',
          ),
        ),
      );
      return;
    }
    await _save(upgraded);
    // Categories were read for the M3U source; the id is unchanged, but the
    // kind now exposes movie/series categories the previous load never asked
    // for.
    await _load();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Upgraded to Xtream. Movies and Series are now available — push to '
          'the cloud panel to keep it across your devices.',
        ),
        duration: Duration(seconds: 5),
      ),
    );
  }

  bool get _hasAnyMatch =>
      ContentKind.values.any((k) => _filtered(k).isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${_config.label} · settings')),
      // Edge-to-edge (targetSdk 35+): keep the category list clear of the system
      // bar (it sits on the side in landscape).
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kSettingsMaxContentWidth,
                  ),
                  // Slivers, not `ListView(children: [...])`. That form is
                  // **not lazy**: it builds every child up front, so a provider
                  // with thousands of categories built thousands of
                  // `FocusableCard`s on the first frame — and again on every
                  // keystroke and every toggle, since each one rebuilds this
                  // screen. That is the "press scroll and it moves the day
                  // after tomorrow" report. The category rows are the only
                  // unbounded part of this screen, so they are the part that
                  // has to be built on demand; everything above them is a fixed
                  // handful of widgets and stays eager.
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        sliver: SliverList.list(
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(6, 8, 6, 12),
                              child: Text(
                                'Turn categories off to hide them — and everything in them '
                                '— from browsing for this source.',
                                style: TextStyle(color: AppColors.textLo),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
                              child: TvTextField(
                                controller: _searchController,
                                hintText: 'Search categories',
                                autofocus: true,
                                textInputAction: TextInputAction.search,
                                prefixIcon: const Icon(Icons.search, size: 20),
                                // The built-in clear button is a real D-pad stop (a
                                // suffixIcon sits behind the edit barrier) — TvTextField.
                                showClear: _query.isNotEmpty,
                                onClear: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                                onChanged: (v) => setState(() => _query = v),
                              ),
                            ),
                            if (_hasAnyMatch)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _BulkButton(
                                        label: 'Show all',
                                        icon: Icons.visibility,
                                        onTap: () => _bulkAll(hide: false),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _BulkButton(
                                        label: 'Hide all',
                                        icon: Icons.visibility_off_outlined,
                                        onTap: () => _bulkAll(hide: true),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(6, 20, 6, 8),
                              child: Text(
                                'Advanced catch-up',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(6, 0, 6, 10),
                              child: Text(
                                'Leave these empty to use provider values. A fixed offset '
                                'takes precedence over the timezone.',
                                style: TextStyle(
                                  color: AppColors.textLo,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            TvTextField(
                              controller: _catchupTimezoneController,
                              hintText: 'Europe/London or UTC',
                              label: 'Provider timezone',
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 8),
                            TvTextField(
                              controller: _catchupOffsetController,
                              hintText: 'e.g. 120',
                              label: 'Fixed offset in minutes',
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 8),
                            TvTextField(
                              controller: _catchupDaysController,
                              hintText: 'e.g. 7',
                              label: 'Maximum archive days',
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _saveCatchupOverrides(),
                            ),
                            if (_catchupError != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
                                child: Text(
                                  _catchupError!,
                                  style: const TextStyle(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 10),
                                child: FilledButton.icon(
                                  onPressed: _saveCatchupOverrides,
                                  icon: const Icon(Icons.save_outlined),
                                  label: const Text('Save catch-up overrides'),
                                ),
                              ),
                            ),
                            // Extra XMLTV guides. Here rather than on the
                            // add/edit source form because it is an ongoing
                            // per-source adjustment rather than part of setting
                            // one up — and because Xtream and Stalker have no
                            // EPG field on that form at all, while both can use
                            // a top-up guide.
                            const Padding(
                              padding: EdgeInsets.fromLTRB(6, 20, 6, 8),
                              child: Text(
                                'EPG guides',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(6, 0, 6, 10),
                              child: Text(
                                'Extra XMLTV guides, used in order to fill in '
                                'channels the guide above them does not cover. '
                                'A channel is only ever served by one guide.',
                                style: TextStyle(
                                  color: AppColors.textLo,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            if (_builtInGuideLabel != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
                                child: Row(
                                  children: [
                                    const Text(
                                      '1. ',
                                      style: TextStyle(
                                        color: AppColors.textLo,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        _builtInGuideLabel!,
                                        style: const TextStyle(
                                          color: AppColors.textLo,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            for (var i = 0; i < _epgControllers.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _EpgGuideRow(
                                  // Rebuild the row when its position changes,
                                  // so removing row 2 of 3 renumbers row 3
                                  // rather than leaving a stale label — and key
                                  // by the controller so the surviving rows
                                  // keep their state through the shuffle.
                                  key: ObjectKey(_epgControllers[i]),
                                  controller: _epgControllers[i],
                                  position:
                                      i + (_builtInGuideLabel == null ? 1 : 2),
                                  onRemove: () => _removeEpgGuide(i),
                                  onSubmitted: _saveEpgGuides,
                                ),
                              ),
                            if (_epgError != null)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                                child: Text(
                                  _epgError!,
                                  style: const TextStyle(
                                    color: AppColors.danger,
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  OutlinedButton.icon(
                                    // The cap counts the built-in guide, so the
                                    // editor offers one fewer row when there is
                                    // one.
                                    onPressed:
                                        _epgControllers.length >=
                                            kMaxEpgGuides -
                                                (_builtInGuideLabel == null
                                                    ? 0
                                                    : 1)
                                        ? null
                                        : _addEpgGuide,
                                    icon: const Icon(Icons.add),
                                    label: const Text('Add guide'),
                                  ),
                                  FilledButton.icon(
                                    onPressed: _saveEpgGuides,
                                    icon: const Icon(Icons.save_outlined),
                                    label: const Text('Save EPG guides'),
                                  ),
                                ],
                              ),
                            ),
                            // Only for an M3U source whose URL carries Xtream
                            // credentials. The load-time upgrade already converts
                            // local sources silently; this is how a **cloud-managed**
                            // one gets there, since that path deliberately leaves
                            // panel-owned sources alone (a pull would revert it) —
                            // and it is the one place the user can ask for it
                            // explicitly and then push.
                            if (couldBeXtreamPanel(_config)) ...[
                              const Padding(
                                padding: EdgeInsets.fromLTRB(6, 20, 6, 8),
                                child: Text(
                                  'Source type',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(6, 0, 6, 10),
                                child: Text(
                                  'This playlist URL looks like an Xtream panel. As '
                                  'an Xtream source it also gives Movies, Series and '
                                  'the subscription expiry, which a playlist can’t '
                                  'carry.',
                                  style: TextStyle(
                                    color: AppColors.textLo,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              _UpgradeToXtreamTile(
                                busy: _upgrading,
                                onTap: _upgradeToXtream,
                              ),
                            ],
                            if (_config.kind == SourceKind.xtream) ...[
                              const Padding(
                                padding: EdgeInsets.fromLTRB(6, 20, 6, 8),
                                child: Text(
                                  'Live stream format',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.fromLTRB(6, 0, 6, 10),
                                child: Text(
                                  'Some providers only serve one stream format — '
                                  'switch this if channels fail to load.',
                                  style: TextStyle(
                                    color: AppColors.textLo,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              _StreamFormatTile(
                                value: _streamExtension,
                                onTap: _cycleStreamExtension,
                              ),
                            ],
                          ],
                        ),
                      ),
                      ..._sectionSlivers('Live TV', ContentKind.live),
                      ..._sectionSlivers('Movies', ContentKind.movie),
                      ..._sectionSlivers('Series', ContentKind.series),
                      const SliverToBoxAdapter(child: SizedBox(height: 32)),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  /// One kind's section: an eager header plus the rows, built on demand.
  ///
  /// The hidden set is resolved **once here**, not per row —
  /// [SourceConfig.hiddenCategoryIds] rebuilds a `Set` from the stored settings
  /// on every call, and the row builder runs per visible row per frame.
  List<Widget> _sectionSlivers(String title, ContentKind kind) {
    final items = _filtered(kind);
    final total = _all(kind).length;
    final hidden = _config.hiddenCategoryIds(kind);
    const horizontal = EdgeInsets.symmetric(horizontal: 12);
    return [
      SliverPadding(
        padding: horizontal,
        sliver: SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (items.isNotEmpty) ...[
                  _BulkButton(
                    label: 'Show all',
                    icon: Icons.visibility,
                    dense: true,
                    onTap: () => _bulkSection(kind, hide: false),
                  ),
                  const SizedBox(width: 6),
                  _BulkButton(
                    label: 'Hide all',
                    icon: Icons.visibility_off_outlined,
                    dense: true,
                    onTap: () => _bulkSection(kind, hide: true),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: horizontal,
        sliver: items.isEmpty
            ? SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                  child: Text(
                    total == 0
                        ? 'Browse this source once to load its categories.'
                        : 'No categories match your search.',
                    style: const TextStyle(
                      color: AppColors.textLo,
                      fontSize: 12,
                    ),
                  ),
                ),
              )
            : SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final item = items[i];
                  return _CategoryToggleRow(
                    title: item.title,
                    enabled: !hidden.contains(item.id),
                    onToggle: () => _toggle(kind, item.id),
                  );
                },
              ),
      ),
    ];
  }
}

/// A compact pill action used for the Show all / Hide all controls. D-pad
/// navigable via [FocusableCard], matching [_CategoryToggleRow].
class _BulkButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool dense;
  final VoidCallback onTap;

  const _BulkButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 10 : 12,
          vertical: dense ? 7 : 10,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: dense ? 16 : 18, color: AppColors.textLo),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: AppColors.textHi,
                fontSize: dense ? 12 : 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "OK to cycle" tri-state row for the per-source Xtream stream format
/// override (`SourceConfig.settings['streamExtension']`). A single focus
/// stop, like [_CategoryToggleRow]; OK/tap cycles Automatic → .ts → .m3u8.
/// [value] is `null` for "unset" — kept distinct from an explicit choice so
/// merely opening this screen never pins a source away from the platform
/// default.
/// Offers the verified M3U → Xtream upgrade. Shown only when the playlist URL
/// carries Xtream credentials; the panel is contacted on tap, never before, so
/// opening this screen costs no network for a source that will never qualify.
class _UpgradeToXtreamTile extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _UpgradeToXtreamTile({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: busy ? () {} : onTap,
      scrollOnFocus: false,
      debugLabel: 'sourceSettings.upgradeXtream',
      semanticsLabel:
          'Upgrade to Xtream, unlocks Movies, Series and the '
          'subscription expiry',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.upgrade, size: 20, color: AppColors.textLo),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Upgrade to Xtream'),
                  Text(
                    'Checks the panel first — nothing changes if it does not '
                    'answer.',
                    style: TextStyle(fontSize: 12, color: AppColors.textLo),
                  ),
                ],
              ),
            ),
            if (busy)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Text(
                'Upgrade',
                style: TextStyle(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StreamFormatTile extends StatelessWidget {
  final String? value;
  final VoidCallback onTap;

  const _StreamFormatTile({required this.value, required this.onTap});

  String get _valueLabel => switch (value) {
    'ts' => 'Always .ts',
    'm3u8' => 'Always .m3u8',
    _ => 'Automatic',
  };

  String get _hint => switch (value) {
    'ts' => 'Live channels always request the .ts format.',
    'm3u8' => 'Live channels always request the .m3u8 format.',
    _ => "Uses this device's default format.",
  };

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onTap,
      scrollOnFocus: false,
      debugLabel: 'sourceSettings.streamFormat',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.swap_horiz, size: 20, color: AppColors.textLo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Stream format'),
                  Text(
                    _hint,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textLo,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _valueLabel,
              style: const TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryToggleRow extends StatelessWidget {
  final String title;
  final bool enabled;
  final VoidCallback onToggle;

  const _CategoryToggleRow({
    required this.title,
    required this.enabled,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: enabled ? AppColors.textHi : AppColors.textLo,
                  fontWeight: enabled ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              enabled ? Icons.visibility : Icons.visibility_off_outlined,
              size: 20,
              color: enabled ? AppColors.accent : AppColors.line,
            ),
          ],
        ),
      ),
    );
  }
}

/// One editable extra-guide URL, with its position and a remove control.
///
/// A plain [Row] of Material controls rather than a [FocusableCard]: the field
/// and the remove button are two separate stops, which is what lets a D-pad
/// reach the button at all — wrapping the pair in one focusable card would make
/// the row a single stop and leave no way to press it.
class _EpgGuideRow extends StatelessWidget {
  const _EpgGuideRow({
    super.key,
    required this.controller,
    required this.position,
    required this.onRemove,
    required this.onSubmitted,
  });

  final TextEditingController controller;

  /// This guide's place in the priority order, counting the built-in guide.
  final int position;

  final VoidCallback onRemove;
  final Future<void> Function() onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TvTextField(
            controller: controller,
            hintText: 'http://.../guide.xml or .xml.gz',
            label: 'Guide $position',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmitted(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close),
            tooltip: 'Remove guide $position',
            color: AppColors.textLo,
          ),
        ),
      ],
    );
  }
}
