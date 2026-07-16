import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/tv_text_field.dart';

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

  List<Category> _live = const [];
  List<MediaCategory> _movies = const [];
  List<MediaCategory> _series = const [];
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
      _live = live;
      _movies = movies;
      _series = series;
      _loading = false;
    });
  }

  /// All categories for [kind] as a uniform (id, title) list.
  List<({String id, String title})> _all(ContentKind kind) {
    switch (kind) {
      case ContentKind.live:
        return _live.map((c) => (id: c.id, title: c.title)).toList();
      case ContentKind.movie:
        return _movies.map((c) => (id: c.id, title: c.title)).toList();
      case ContentKind.series:
        return _series.map((c) => (id: c.id, title: c.title)).toList();
      case ContentKind.season:
      case ContentKind.episode:
        return const [];
    }
  }

  /// [kind]'s categories matching the current search query.
  List<({String id, String title})> _filtered(ContentKind kind) {
    final q = _query.trim().toLowerCase();
    final all = _all(kind);
    if (q.isEmpty) return all;
    return all.where((c) => c.title.toLowerCase().contains(q)).toList();
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

  bool get _hasAnyMatch =>
      ContentKind.values.any((k) => _filtered(k).isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${_config.label} · settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
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
                    style: TextStyle(color: AppColors.textLo, fontSize: 12),
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
                      style: const TextStyle(color: Colors.redAccent),
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
                _section('Live TV', ContentKind.live),
                _section('Movies', ContentKind.movie),
                _section('Series', ContentKind.series),
              ],
            ),
    );
  }

  Widget _section(String title, ContentKind kind) {
    final items = _filtered(kind);
    final total = _all(kind).length;
    final hidden = _config.hiddenCategoryIds(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
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
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              total == 0
                  ? 'Browse this source once to load its categories.'
                  : 'No categories match your search.',
              style: const TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          )
        else
          for (final item in items)
            _CategoryToggleRow(
              title: item.title,
              enabled: !hidden.contains(item.id),
              onToggle: () => _toggle(kind, item.id),
            ),
      ],
    );
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
