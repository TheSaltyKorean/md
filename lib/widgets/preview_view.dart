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
/// entire document. Fenced code blocks get a copy button; tables get a
/// "Copy table" chip that copies spreadsheet-ready TSV.
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

  static Future<void> _launch(String href) async {
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    // Launch directly: canLaunchUrl can falsely return false on Android 11+
    // due to package visibility, making links appear dead.
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {/* no handler available */}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final styleSheet = _styleSheet(theme);
    return SelectionArea(
      child: Markdown(
        data: markdown,
        controller: controller,
        // SelectionArea provides selection for the whole document; the
        // widget's own per-block SelectableText would nest inside it and
        // assert, so it stays off here.
        selectable: false,
        padding: padding,
        // The real GFM parser identifies tables; we wrap each one with a
        // "Copy table" chip but let the PACKAGE render the table itself
        // (keeping selection, images, zoom, alignment, and inline
        // formatting) — see _CopyableTableSyntax.
        blockSyntaxes: [_CopyableTableSyntax()],
        // flutter_markdown_plus doesn't handle inline HTML, so parse <u>…</u>
        // ourselves and render it underlined (matches the PDF export).
        inlineSyntaxes: [_UnderlineSyntax()],
        builders: {
          'u': _UnderlineElementBuilder(),
          // Custom fenced-code-block rendering with a copy button. The
          // package still wraps the returned widget in codeblockDecoration.
          'pre': _CodeBlockBuilder(theme),
          // The injected "Copy table" chip (inline, so it doesn't grow the
          // package's block-tag registry the way a block builder would).
          'copytable': _CopyTableChipBuilder(),
        },
        styleSheet: styleSheet,
        onTapLink: (text, href, title) async {
          if (href != null) await _launch(href);
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

// --- Code blocks ------------------------------------------------------------

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

// --- Tables (copy as TSV) ---------------------------------------------------

/// A per-parse Expando linking an injected `copytable` chip element to the
/// table it belongs to, so the chip builder can compute the TSV from the
/// table's real (inline-parsed) cells at build time.
final Expando<md.Element> _chipTable = Expando('mdChipTable');

/// The GFM table syntax, wrapped so a "Copy table" chip is emitted above each
/// table. The table itself keeps its `table` tag, so the package renders it
/// with full fidelity (selection, images, zoom, inline formatting, alignment);
/// we only add the chip.
///
/// The wrapper is a `section` — a built-in block tag the package lays out as a
/// column of its children, and (crucially) one we register no *block* builder
/// for, so nothing is appended to the package's library-level block-tag list
/// on every keystroke. The chip is an inline `copytable` element for the same
/// reason.
class _CopyableTableSyntax extends md.TableSyntax {
  @override
  md.Node? parse(md.BlockParser parser) {
    final node = super.parse(parser);
    if (node is md.Element && node.tag == 'table') {
      final chip = md.Element('copytable', []);
      _chipTable[chip] = node; // resolve the TSV from real cells at build time
      return md.Element('section', [
        md.Element('p', [chip]),
        node,
      ]);
    }
    return node;
  }
}

/// Renders the inline "Copy table" chip. Reads the associated table (via
/// [_chipTable]) whose cells are inline-parsed by now, so the TSV has decoded
/// entities and the parser's normalised column counts.
class _CopyTableChipBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final table = _chipTable[element];
    if (table == null) return const SizedBox.shrink();
    final tsv = _tableTsv(table);
    if (tsv.isEmpty) return const SizedBox.shrink();
    return _CopyTableChip(tsv: tsv);
  }
}

/// Tab-separated text of a parsed `<table>`: header row + body rows, each
/// normalised to the header's column count (matching the rendered grid), with
/// tabs/newlines inside a cell collapsed so they can't break the grid.
String _tableTsv(md.Element table) {
  final rows = <List<md.Element>>[];
  for (final section in table.children ?? const <md.Node>[]) {
    if (section is! md.Element) continue;
    for (final row in section.children ?? const <md.Node>[]) {
      if (row is! md.Element || row.tag != 'tr') continue;
      rows.add([
        for (final c in row.children ?? const <md.Node>[])
          if (c is md.Element) c
      ]);
    }
  }
  if (rows.isEmpty) return '';
  final cols = rows.first.length;
  String cell(md.Element? c) =>
      (c?.textContent ?? '').replaceAll(RegExp(r'[\t\n]+'), ' ').trim();
  return rows
      .map((r) => [
            for (var i = 0; i < cols; i++) cell(i < r.length ? r[i] : null)
          ].join('\t'))
      .join('\n');
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
    );
  }
}

// --- Inline HTML underline --------------------------------------------------

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
