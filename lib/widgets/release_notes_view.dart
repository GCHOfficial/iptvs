import 'package:flutter/material.dart';

import '../theme.dart';

/// Renders a GitHub release's changelog (`ReleaseInfo.notes`) as tidy formatted
/// text instead of raw markdown. Deliberately tiny and dependency-free — it
/// covers the shapes GitHub actually emits (auto-generated notes plus the usual
/// hand-written headings/bullets), not the whole CommonMark spec:
///
///  * `#`…`######` headings → bold, sized by level,
///  * `*` / `-` / `+` list items → a bullet + inline-formatted text; indented
///    items render as nested bullets (one extra level of inset),
///  * `**bold**` / `__bold__` → emphasised spans; `*italic*` → italics;
///    `` `code` `` → a monospace chip; ``` fence lines are dropped,
///  * `[text](url)` → just `text`; `…/pull/123` → `#123`; `…/compare/a...b` →
///    `a…b`; any other bare URL → its last path segment — so links read as
///    short labels rather than long noise (the dialog's own button opens the
///    full release page).
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView(this.notes, {super.key});

  final String notes;

  static const _bodyStyle = TextStyle(
    color: AppColors.textLo,
    fontSize: 13,
    height: 1.4,
  );
  static const _boldStyle = TextStyle(
    color: AppColors.textHi,
    fontWeight: FontWeight.w700,
  );
  static const _italicStyle = TextStyle(fontStyle: FontStyle.italic);
  static const _codeStyle = TextStyle(
    color: AppColors.textHi,
    fontFamily: 'monospace',
    backgroundColor: AppColors.panelHi,
  );

  @override
  Widget build(BuildContext context) {
    final blocks = <Widget>[];
    final lines = notes.replaceAll('\r\n', '\n').split('\n');
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        // Collapse runs of blank lines into a single gap.
        if (blocks.isNotEmpty && blocks.last is! SizedBox) {
          blocks.add(const SizedBox(height: 8));
        }
        continue;
      }
      // Drop code-fence markers; the fenced lines render as plain body text.
      if (line.startsWith('```')) continue;

      final heading = _headingPattern.firstMatch(line);
      if (heading != null) {
        final level = heading.group(1)!.length;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 4, bottom: 2),
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  color: AppColors.textHi,
                  fontSize: level <= 1 ? 16 : 14,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
                children: _inlineSpans(heading.group(2)!),
              ),
            ),
          ),
        );
        continue;
      }

      final bullet = _bulletPattern.firstMatch(line);
      if (bullet != null) {
        // One extra inset level for indented (nested) list items.
        final nested = raw.length - raw.trimLeft().length >= 2;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(left: nested ? 18 : 2, top: 2, bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 6, right: 8, left: 2),
                  child: Icon(Icons.circle, size: 5, color: AppColors.textLo),
                ),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: _bodyStyle,
                      children: _inlineSpans(bullet.group(1)!),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }

      blocks.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: RichText(
            text: TextSpan(style: _bodyStyle, children: _inlineSpans(line)),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }
}

final _headingPattern = RegExp(r'^(#{1,6})\s+(.*)$');
final _bulletPattern = RegExp(r'^[*\-+]\s+(.*)$');
final _mdLinkPattern = RegExp(r'\[([^\]]+)\]\([^)]*\)');
final _pullInPattern = RegExp(r'\bin\s+https?://\S*?/pull/(\d+)\b');
final _comparePattern = RegExp(r'https?://\S*?/compare/(\S+?)\.\.\.(\S+)');
final _bareUrlPattern = RegExp(r'https?://\S+');
final _boldPattern = RegExp(r'\*\*(.+?)\*\*|__(.+?)__');
final _codePattern = RegExp(r'`([^`]+)`');
// Single-asterisk italics only — `_x_` would mangle snake_case identifiers.
final _italicPattern = RegExp(r'\*([^*]+)\*');

/// Collapse links/URLs to short labels, then split the inline markers into
/// styled spans — `` `code` `` first (so markers inside code stay literal),
/// then `**bold**`, then `*italic*` in what remains.
List<InlineSpan> _inlineSpans(String text) {
  final cleaned = _shortenLinks(text);
  final spans = <InlineSpan>[];
  _emitCode(cleaned, spans);
  if (spans.isEmpty) spans.add(TextSpan(text: cleaned));
  return spans;
}

void _emitCode(String text, List<InlineSpan> out) {
  var last = 0;
  for (final m in _codePattern.allMatches(text)) {
    if (m.start > last) _emitBold(text.substring(last, m.start), out);
    out.add(TextSpan(text: m.group(1), style: ReleaseNotesView._codeStyle));
    last = m.end;
  }
  if (last < text.length) _emitBold(text.substring(last), out);
}

void _emitBold(String text, List<InlineSpan> out) {
  var last = 0;
  for (final m in _boldPattern.allMatches(text)) {
    if (m.start > last) _emitItalic(text.substring(last, m.start), out);
    out.add(
      TextSpan(
        text: m.group(1) ?? m.group(2) ?? '',
        style: ReleaseNotesView._boldStyle,
      ),
    );
    last = m.end;
  }
  if (last < text.length) _emitItalic(text.substring(last), out);
}

void _emitItalic(String text, List<InlineSpan> out) {
  var last = 0;
  for (final m in _italicPattern.allMatches(text)) {
    if (m.start > last) {
      out.add(TextSpan(text: text.substring(last, m.start)));
    }
    out.add(TextSpan(text: m.group(1), style: ReleaseNotesView._italicStyle));
    last = m.end;
  }
  if (last < text.length) out.add(TextSpan(text: text.substring(last)));
}

String _shortenLinks(String s) {
  var out = s.replaceAllMapped(_mdLinkPattern, (m) => m.group(1)!);
  out = out.replaceAllMapped(_pullInPattern, (m) => '(#${m.group(1)})');
  out = out.replaceAllMapped(
    _comparePattern,
    (m) => '${m.group(1)}…${m.group(2)}',
  );
  out = out.replaceAllMapped(_bareUrlPattern, (m) => _shortUrl(m.group(0)!));
  return out;
}

String _shortUrl(String url) {
  try {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty) return segments.last;
    if (uri.host.isNotEmpty) return uri.host;
  } catch (_) {
    // fall through
  }
  return url;
}
