import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

/// Renders Markdown to a styled, scrollable, read-only view. Used both for the
/// preview pane of the split view and for the full-screen read-only mode.
///
/// The whole render sits inside a [SelectionArea] so text can be highlighted
/// and copied with the native context menu / keyboard shortcut across the
/// entire document (not just one block at a time). Fenced code blocks also get
/// an explicit copy button in their top-right corner.
class PreviewView extends StatelessWidget {
  const PreviewView({
    super.key,
    required this.markdown,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 80),
    this.controller,
  });

  final String markdown;
  final EdgeInsets padding;

  /// Optional external scroll controller (used by the split view to keep the
  /// preview in sync with the source editor).
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Inject a "Copy table" marker above each table and collect each table's
    // tab-separated text. The table itself still renders via the package
    // (untouched); the marker becomes a small chip that copies spreadsheet-
    // ready TSV — plain selection only yields run-together text that Excel
    // pastes into a single cell.
    final (transformed, tsvByIndex) = injectTableCopyMarkers(markdown);
    return SelectionArea(
      child: Markdown(
        data: transformed,
        controller: controller,
        // SelectionArea provides selection for the whole document; the
        // widget's own per-block SelectableText would nest inside it and
        // assert, so it stays off here.
        selectable: false,
        padding: padding,
        // flutter_markdown_plus doesn't handle inline HTML, so parse <u>…</u>
        // ourselves and render it underlined (matches the PDF export).
        inlineSyntaxes: [_UnderlineSyntax(), _CopyTableSyntax()],
        builders: {
          'u': _UnderlineElementBuilder(),
          // Custom fenced-code-block rendering with a copy button. The
          // package still wraps the returned widget in codeblockDecoration.
          'pre': _CodeBlockBuilder(theme),
          // The injected "Copy table" chip above each table.
          'copytable': _CopyTableButtonBuilder(tsvByIndex),
        },
        styleSheet: _styleSheet(theme),
        onTapLink: (text, href, title) async {
          if (href == null) return;
          final uri = Uri.tryParse(href);
          if (uri == null) return;
          // Launch directly: canLaunchUrl can falsely return false on
          // Android 11+ due to package visibility, making links appear dead.
          try {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          } catch (_) {/* no handler available */}
        },
      ),
    );
  }

  MarkdownStyleSheet _styleSheet(ThemeData theme) {
    final cs = theme.colorScheme;
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
      h1: theme.textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.bold, color: cs.onSurface),
      h2: theme.textTheme.headlineSmall
          ?.copyWith(fontWeight: FontWeight.bold, color: cs.onSurface),
      h3: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      blockquoteDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: cs.primary, width: 4)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      code: TextStyle(
        backgroundColor: cs.surfaceContainerHighest,
        fontFamily: 'monospace',
        fontSize: 14,
        color: cs.primary,
      ),
      codeblockDecoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      codeblockPadding: const EdgeInsets.all(14),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(width: 1, color: cs.outlineVariant),
        ),
      ),
      tableBorder: TableBorder.all(color: cs.outlineVariant),
      tableHead: const TextStyle(fontWeight: FontWeight.bold),
      a: TextStyle(color: cs.primary, decoration: TextDecoration.underline),
    );
  }
}

/// Renders a fenced code block (`<pre>`) with a copy button pinned to the
/// top-right corner. The package wraps whatever this returns in the
/// stylesheet's `codeblockDecoration`, so the button ends up inside the
/// rounded code box.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.theme);

  final ThemeData theme;

  // No isBlockElement() override: `pre` is already a built-in block tag, and
  // returning true here would append 'pre' to the package's library-level
  // block-tag list on every parse (i.e. every keystroke in the split view),
  // growing it unbounded and slowing all later tag checks.

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // The <pre> wraps a <code> whose text is the block body; textContent
    // flattens it. Drop the single trailing newline the parser appends.
    var code = element.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);

    final cs = theme.colorScheme;
    final codeStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 14,
      height: 1.45,
      color: cs.onSurfaceVariant,
    );

    return Stack(
      children: [
        // The button gutter is reserved OUTSIDE the scroll view, so a long
        // line's start never paints under the button at scroll offset 0 (the
        // scrollable viewport simply ends before the button). Long lines
        // scroll horizontally rather than soft-wrapping, matching the
        // package's default code-block behaviour that this builder replaces.
        Padding(
          padding: const EdgeInsets.only(right: 36),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(14),
            child: Text(code, style: codeStyle, softWrap: false),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: _CopyButton(text: code),
        ),
      ],
    );
  }
}

/// A compact icon button that copies [text] to the clipboard and briefly
/// shows a check mark as confirmation. Excluded from text selection so it
/// doesn't interfere with highlighting the code.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SelectionContainer.disabled(
      child: IconButton(
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(),
        tooltip: _copied ? 'Copied' : 'Copy code',
        icon: Icon(
          _copied ? Icons.check_rounded : Icons.copy_rounded,
          color: _copied ? Colors.green : cs.onSurfaceVariant,
        ),
        onPressed: _copy,
      ),
    );
  }
}

// --- Table copy (TSV for spreadsheets) --------------------------------------

/// Private-use marker char that can't appear in real document text, used to
/// splice the "Copy table" affordance into the markdown before each table.
const String _tableMarkerChar = '\uE000';

/// Scans [markdown] for block-level GFM tables and returns a copy of it with a
/// `Copy table` marker paragraph inserted above each one, plus a map from
/// marker index to that table's tab-separated (TSV) text — what a spreadsheet
/// needs to split the paste into cells.
///
/// A table is only marked when it's clearly its own block (preceded by a blank
/// line or the document start) so the injection can never turn non-table text
/// into a table. Anything it doesn't recognise simply gets no chip — the table
/// still renders normally.
@visibleForTesting
(String, Map<int, String>) injectTableCopyMarkers(String markdown) {
  final lines = markdown.split('\n');
  final out = <String>[];
  final tsv = <int, String>{};
  var index = 0;
  var i = 0;

  bool isRow(String l) => l.contains('|');
  bool isDelimiter(String l) {
    final t = l.trim();
    return t.contains('-') &&
        RegExp(r'^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$').hasMatch(t);
  }

  while (i < lines.length) {
    final blockStart = i == 0 || lines[i - 1].trim().isEmpty;
    if (blockStart &&
        i + 1 < lines.length &&
        isRow(lines[i]) &&
        isDelimiter(lines[i + 1])) {
      final tableLines = <String>[lines[i], lines[i + 1]];
      var j = i + 2;
      while (
          j < lines.length && lines[j].trim().isNotEmpty && isRow(lines[j])) {
        tableLines.add(lines[j]);
        j++;
      }
      final rows = <List<String>>[];
      for (var k = 0; k < tableLines.length; k++) {
        if (k == 1) continue; // skip the |---|---| delimiter row
        rows.add(_splitRow(tableLines[k]));
      }
      tsv[index] = rows.map((r) => r.join('\t')).join('\n');
      // Separate the marker into its own paragraph above the table.
      if (out.isNotEmpty && out.last.trim().isNotEmpty) out.add('');
      out.add('$_tableMarkerChar$index$_tableMarkerChar');
      out.add('');
      out.addAll(tableLines);
      index++;
      i = j;
    } else {
      out.add(lines[i]);
      i++;
    }
  }
  return (out.join('\n'), tsv);
}

/// Split a `| a | b |` row into cell values: honour escaped `\|`, drop the
/// outer pipes, and strip common inline markdown so the pasted value is plain
/// text (e.g. `**Bold**` → `Bold`, `[x](url)` → `x`). Tabs/newlines inside a
/// cell collapse to a space so they can't break the TSV grid.
List<String> _splitRow(String row) {
  final cells = <String>[];
  final buf = StringBuffer();
  final l = row.trim();
  for (var k = 0; k < l.length; k++) {
    final ch = l[k];
    if (ch == r'\' && k + 1 < l.length && l[k + 1] == '|') {
      buf.write('|');
      k++;
    } else if (ch == '|') {
      cells.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  cells.add(buf.toString());
  // Drop empty first/last cells produced by the leading/trailing pipes.
  if (cells.isNotEmpty && cells.first.trim().isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty && cells.last.trim().isEmpty) {
    cells.removeLast();
  }
  return [for (final c in cells) _plainCell(c)];
}

String _plainCell(String cell) {
  var s = cell.trim();
  s = s.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1] ?? ''); // links → text
  s = s.replaceAll(RegExp(r'\*\*|__|\*|_|`|~~'), ''); // emphasis / code / del
  s = s.replaceAll(RegExp(r'[\t\n]+'), ' ');
  return s.trim();
}

/// Turns the injected `<index>` marker into a `copytable` element
/// carrying the index the builder resolves to a TSV string.
class _CopyTableSyntax extends md.InlineSyntax {
  _CopyTableSyntax() : super('$_tableMarkerChar(\\d+)$_tableMarkerChar');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
        md.Element.empty('copytable')..attributes['idx'] = match[1] ?? '');
    return true;
  }
}

/// Renders the "Copy table" chip for an injected marker.
class _CopyTableButtonBuilder extends MarkdownElementBuilder {
  _CopyTableButtonBuilder(this.tsvByIndex);

  final Map<int, String> tsvByIndex;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final idx = int.tryParse(element.attributes['idx'] ?? '');
    final tsv = idx == null ? null : tsvByIndex[idx];
    if (tsv == null) return const SizedBox.shrink();
    return _CopyTableChip(tsv: tsv);
  }
}

/// A small labelled "Copy table" chip that copies tab-separated text (pastes
/// into Excel / Sheets as separate cells) and confirms with a check.
class _CopyTableChip extends StatefulWidget {
  const _CopyTableChip({required this.tsv});

  final String tsv;

  @override
  State<_CopyTableChip> createState() => _CopyTableChipState();
}

class _CopyTableChipState extends State<_CopyTableChip> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.tsv));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SelectionContainer.disabled(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: Icon(
              _copied ? Icons.check_rounded : Icons.grid_on_rounded,
              size: 16,
              color: _copied ? Colors.green : cs.onSurfaceVariant,
            ),
            label: Text(_copied ? 'Copied' : 'Copy table'),
            tooltip: 'Copy as tab-separated values (paste into a spreadsheet)',
            onPressed: _copy,
          ),
        ),
      ),
    );
  }
}

/// Parses `<u>…</u>` inline HTML into a `u` element for the preview renderer.
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax() : super(r'<u>([\s\S]*?)</u>');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match[1] ?? ''));
    return true;
  }
}

/// Renders the `u` element produced by [_UnderlineSyntax] as underlined text.
class _UnderlineElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    return Text(
      text.text,
      style: (preferredStyle ?? const TextStyle())
          .copyWith(decoration: TextDecoration.underline),
    );
  }
}
