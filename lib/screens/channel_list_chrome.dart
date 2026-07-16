import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show KeyEvent, KeyRepeatEvent;

import '../sources/source.dart';
import '../theme.dart';
import '../widgets/tv_text_field.dart';

const _toolbarControlHeight = 40.0;

/// Content-kind tabs at the top of [ChannelListScreen].
///
/// Focus nodes are supplied by the screen so the Back ladder can retain
/// ownership and jump directly to the selected tab.
class ChannelContentTabs extends StatelessWidget {
  final ContentKind value;
  final ValueChanged<ContentKind> onChanged;
  final Map<ContentKind, FocusNode> focusNodes;

  const ChannelContentTabs({
    super.key,
    required this.value,
    required this.onChanged,
    required this.focusNodes,
  });

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TabChip(
              icon: Icons.live_tv_rounded,
              label: 'Live',
              selected: value == ContentKind.live,
              focusNode: focusNodes[ContentKind.live],
              onTap: () => onChanged(ContentKind.live),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.movie_outlined,
              label: 'Movies',
              selected: value == ContentKind.movie,
              focusNode: focusNodes[ContentKind.movie],
              onTap: () => onChanged(ContentKind.movie),
            ),
            const SizedBox(width: 8),
            _TabChip(
              icon: Icons.tv_outlined,
              label: 'Series',
              selected: value == ContentKind.series,
              focusNode: focusNodes[ContentKind.series],
              onTap: () => onChanged(ContentKind.series),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _TabChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.focusNode,
    required this.onTap,
  });

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected;
    final background = active
        ? AppColors.accent
        : (_focused ? AppColors.panelHi : AppColors.panel);
    final foreground = active ? Colors.white : AppColors.textHi;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (value) {
        if (mounted) setState(() => _focused = value);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: _toolbarControlHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(AppRadius.tile),
            border: Border.all(
              color: _focused
                  ? (active ? Colors.white : AppColors.accent)
                  : AppColors.line,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search, category, and per-tab action controls.
class ChannelToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final String query;
  final String hintText;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onClearQuery;
  final FocusNode? searchCellFocusNode;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchCellKeyEvent;
  final Widget? categoryControl;
  final Widget? actionControl;

  const ChannelToolbar({
    super.key,
    required this.searchController,
    required this.query,
    required this.hintText,
    required this.onQueryChanged,
    required this.onClearQuery,
    this.searchCellFocusNode,
    this.onSearchCellKeyEvent,
    this.categoryControl,
    this.actionControl,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 620;
        final search = TvTextField(
          controller: searchController,
          hintText: hintText,
          height: _toolbarControlHeight,
          cellFocusNode: searchCellFocusNode,
          onChanged: onQueryChanged,
          textInputAction: TextInputAction.search,
          prefixIcon: const Icon(Icons.search, size: 20),
          showClear: query.isNotEmpty,
          onClear: onClearQuery,
        );
        final trailing = _trailingControls();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: onSearchCellKeyEvent,
            child: narrow
                ? Column(
                    children: [
                      search,
                      if (trailing != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: double.infinity,
                            child: trailing,
                          ),
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: search),
                      if (categoryControl != null) ...[
                        const SizedBox(width: 12),
                        categoryControl!,
                      ],
                      if (actionControl != null) ...[
                        const SizedBox(width: 8),
                        actionControl!,
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget? _trailingControls() {
    if (categoryControl == null) return actionControl;
    if (actionControl == null) return categoryControl;
    return Row(
      children: [
        Expanded(child: categoryControl!),
        const SizedBox(width: 8),
        actionControl!,
      ],
    );
  }
}

class ChannelToolbarIconButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;

  const ChannelToolbarIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.busy = false,
  });

  @override
  State<ChannelToolbarIconButton> createState() =>
      _ChannelToolbarIconButtonState();
}

class _ChannelToolbarIconButtonState extends State<ChannelToolbarIconButton> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox.square(
        dimension: _toolbarControlHeight,
        child: IconButton.filledTonal(
          focusNode: _node,
          style: IconButton.styleFrom(
            backgroundColor: _focused ? AppColors.panelHi : AppColors.panel,
            foregroundColor: AppColors.textHi,
            disabledBackgroundColor: AppColors.panel,
            disabledForegroundColor: AppColors.textLo,
            overlayColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.control),
              side: BorderSide(
                color: _focused ? AppColors.accent : AppColors.line,
                width: _focused ? 2 : 1,
              ),
            ),
          ),
          onPressed: widget.onPressed,
          icon: Icon(widget.icon, size: 20),
        ),
      ),
    );
  }
}

class ChannelCategoryDropdown extends StatelessWidget {
  final List<Category> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const ChannelCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: value,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: const Text(
          'All categories',
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All categories'),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class MediaCategoryDropdown extends StatelessWidget {
  final List<MediaCategory> categories;
  final String? value;
  final ValueChanged<String?> onChanged;

  const MediaCategoryDropdown({
    super.key,
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _DropdownFrame(
      builder: (focusNode) => DropdownButton<String?>(
        focusNode: focusNode,
        focusColor: Colors.transparent,
        isDense: true,
        isExpanded: true,
        value: value,
        dropdownColor: AppColors.panelHi,
        borderRadius: BorderRadius.circular(AppRadius.control),
        icon: const Icon(Icons.expand_more, color: AppColors.textLo),
        hint: const Text(
          'All categories',
          style: TextStyle(color: AppColors.textLo),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('All categories'),
          ),
          ...categories.map(
            (category) => DropdownMenuItem<String?>(
              value: category.id,
              child: Text(
                category.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _DropdownFrame extends StatefulWidget {
  final Widget Function(FocusNode focusNode) builder;

  const _DropdownFrame({required this.builder});

  @override
  State<_DropdownFrame> createState() => _DropdownFrameState();
}

class _DropdownFrameState extends State<_DropdownFrame> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _node.addListener(_sync);
  }

  void _sync() {
    if (mounted && _focused != _node.hasFocus) {
      setState(() => _focused = _node.hasFocus);
    }
  }

  @override
  void dispose() {
    _node.removeListener(_sync);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _toolbarControlHeight,
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _focused ? AppColors.panelHi : AppColors.panel,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(
          color: _focused ? AppColors.accent : AppColors.line,
          width: _focused ? 2 : 1,
        ),
      ),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => event is KeyRepeatEvent
            ? KeyEventResult.handled
            : KeyEventResult.ignored,
        child: DropdownButtonHideUnderline(child: widget.builder(_node)),
      ),
    );
  }
}
