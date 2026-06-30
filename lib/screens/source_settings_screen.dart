import 'package:flutter/material.dart';

import '../data/app_database.dart';
import '../data/source_store.dart';
import '../sources/source.dart';
import '../sources/source_config.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // The cache is keyed by the credential-derived [Source.id] (e.g.
    // `stalker:portal|mac`), NOT the [SourceConfig] UUID — so resolve the
    // built source's id to read the categories browsing stored.
    final source = _config.build();
    final sourceId = source.id;
    await source.dispose();
    final live = await widget.db.readCategories(sourceId);
    final movies =
        await widget.db.readMediaCategories(sourceId, ContentKind.movie);
    final series =
        await widget.db.readMediaCategories(sourceId, ContentKind.series);
    if (!mounted) return;
    setState(() {
      _live = live;
      _movies = movies;
      _series = series;
      _loading = false;
    });
  }

  Future<void> _toggle(ContentKind kind, String categoryId) async {
    final hidden = _config.hiddenCategoryIds(kind).toSet();
    if (!hidden.add(categoryId)) hidden.remove(categoryId);
    final next = _config.withHiddenCategories(kind, hidden);
    setState(() => _config = next);
    await widget.store.save(next);
  }

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
                _section('Live TV', ContentKind.live,
                    _live.map((c) => (id: c.id, title: c.title))),
                _section('Movies', ContentKind.movie,
                    _movies.map((c) => (id: c.id, title: c.title))),
                _section('Series', ContentKind.series,
                    _series.map((c) => (id: c.id, title: c.title))),
              ],
            ),
    );
  }

  Widget _section(
    String title,
    ContentKind kind,
    Iterable<({String id, String title})> categories,
  ) {
    final items = categories.toList();
    final hidden = _config.hiddenCategoryIds(kind);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.textLo,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              'Browse this source once to load its categories.',
              style: TextStyle(color: AppColors.textLo, fontSize: 12),
            ),
          )
        else
          for (final item in items)
            _CategoryToggleRow(
              title: item.title,
              enabled: !hidden.contains(item.id),
              autofocus: kind == ContentKind.live && item.id == items.first.id,
              onToggle: () => _toggle(kind, item.id),
            ),
      ],
    );
  }
}

class _CategoryToggleRow extends StatelessWidget {
  final String title;
  final bool enabled;
  final bool autofocus;
  final VoidCallback onToggle;

  const _CategoryToggleRow({
    required this.title,
    required this.enabled,
    required this.autofocus,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
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
