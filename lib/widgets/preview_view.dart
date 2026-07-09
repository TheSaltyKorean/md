import 'package:flutter/gestures.dart';
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
        // Parse tables to an `mdtable` element instead of `table` — the
        // package hard-codes `table` rendering, so a `table` builder can't
        // add the copy chip, but a renamed tag routes to our own renderer
        // (which reuses the real parser's structure, so every GFM rule —
        // column counts, entity decoding, code-fence exclusion — holds).
        blockSyntaxes: [_CopyableTableSyntax()],
        // flutter_markdown_plus doesn't handle inline HTML, so parse <u>…</u>
        // ourselves and render it underlined (matches the PDF export).
        inlineSyntaxes: [_UnderlineSyntax()],
        builders: {
          'u': _UnderlineElementBuilder(),
          // Custom fenced-code-block rendering with a copy button. The
          // package still wraps the returned widget in codeblockDecoration.
          'pre': _CodeBlockBuilder(theme),
          'mdtable': _TableBuilder(styleSheet, _launch),
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

/// The GFM table syntax, but relabelled `table` → `mdtable` so [_TableBuilder]
/// (rather than the package's hard-coded table handling) renders it. Uses the
/// real parser, so table detection is exactly GFM's: correct column counts,
/// decoded entities, and no false positives inside code blocks.
class _CopyableTableSyntax extends md.TableSyntax {
  // The package's block visitor handles `tr`/`th`/`td` assuming a `table`
  // context it builds itself, so renaming only `table` would make it choke on
  // the still-`tr` rows. Rename the WHOLE structure to inert `md…` tags; the
  // cells' UnparsedContent still flows through the inline pass (so bold,
  // links, entities parse), and [_MarkdownTable] reads the `md…` tags.
  static const _rename = {
    'table': 'mdtable',
    'thead': 'mdthead',
    'tbody': 'mdtbody',
    'tr': 'mdtr',
    'th': 'mdth',
    'td': 'mdtd',
  };

  md.Node _relabel(md.Node node) {
    if (node is! md.Element) return node;
    final tag = _rename[node.tag];
    if (tag == null) return node; // inline cell content — leave untouched
    return md.Element(tag, node.children?.map(_relabel).toList())
      ..attributes.addAll(node.attributes);
  }

  @override
  md.Node? parse(md.BlockParser parser) {
    final node = super.parse(parser);
    if (node is md.Element && node.tag == 'table') return _relabel(node);
    return node;
  }
}

/// Routes the parsed `mdtable` element to the [_MarkdownTable] renderer.
class _TableBuilder extends MarkdownElementBuilder {
  _TableBuilder(this.styleSheet, this.onTapLink);

  final MarkdownStyleSheet styleSheet;
  final void Function(String href) onTapLink;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) =>
      _MarkdownTable(
          element: element, styleSheet: styleSheet, onTapLink: onTapLink);
}

/// Renders a parsed table faithfully (inline formatting, links, alignment)
/// with a "Copy table" chip above it. Stateful so link tap recognizers can be
/// disposed. The TSV is computed from the parser's normalised cells, so the
/// clipboard always matches the rendered grid.
class _MarkdownTable extends StatefulWidget {
  const _MarkdownTable({
    required this.element,
    required this.styleSheet,
    required this.onTapLink,
  });

  final md.Element element;
  final MarkdownStyleSheet styleSheet;
  final void Function(String href) onTapLink;

  @override
  State<_MarkdownTable> createState() => _MarkdownTableState();
}

class _MarkdownTableState extends State<_MarkdownTable> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  /// Rows as (cells, isHeader). Cells are the `mdth`/`mdtd` elements (the
  /// relabelled `th`/`td` — see [_CopyableTableSyntax]).
  List<(List<md.Element>, bool)> _rows() {
    final rows = <(List<md.Element>, bool)>[];
    for (final section in widget.element.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      final isHead = section.tag == 'mdthead';
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'mdtr') continue;
        final cells = [
          for (final c in row.children ?? const <md.Node>[])
            if (c is md.Element) c
        ];
        rows.add((cells, isHead));
      }
    }
    return rows;
  }

  String _cellText(md.Element? cell) =>
      (cell?.textContent ?? '').replaceAll(RegExp(r'[\t\n]+'), ' ').trim();

  TextAlign _align(md.Element cell) => switch (cell.attributes['align']) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        _ => TextAlign.left,
      };

  List<InlineSpan> _spans(List<md.Node>? nodes, TextStyle base) {
    final cs = Theme.of(context).colorScheme;
    final out = <InlineSpan>[];
    for (final n in nodes ?? const <md.Node>[]) {
      if (n is md.Text) {
        out.add(TextSpan(text: n.text, style: base));
        continue;
      }
      if (n is! md.Element) continue;
      switch (n.tag) {
        case 'strong':
          out.addAll(
              _spans(n.children, base.copyWith(fontWeight: FontWeight.bold)));
        case 'em':
          out.addAll(
              _spans(n.children, base.copyWith(fontStyle: FontStyle.italic)));
        case 'del':
          out.addAll(_spans(n.children,
              base.copyWith(decoration: TextDecoration.lineThrough)));
        case 'u':
          out.addAll(_spans(
              n.children, base.copyWith(decoration: TextDecoration.underline)));
        case 'code':
          out.add(TextSpan(
              text: n.textContent,
              style: base.copyWith(
                  fontFamily: 'monospace',
                  backgroundColor: cs.surfaceContainerHighest)));
        case 'br':
          out.add(const TextSpan(text: '\n'));
        case 'a':
          final href = n.attributes['href'];
          final linkStyle = base.copyWith(
              color: cs.primary, decoration: TextDecoration.underline);
          if (href == null) {
            out.addAll(_spans(n.children, linkStyle));
          } else {
            final rec = TapGestureRecognizer()
              ..onTap = () => widget.onTapLink(href);
            _recognizers.add(rec);
            out.add(TextSpan(
                text: n.textContent, style: linkStyle, recognizer: rec));
          }
        default:
          out.addAll(_spans(n.children, base));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // Recognizers are recreated each build; dispose the previous set first.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final rows = _rows();
    if (rows.isEmpty) return const SizedBox.shrink();
    final cols = rows.first.$1.length;
    if (cols == 0) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final base = DefaultTextStyle.of(context).style.copyWith(fontSize: 14);

    // TSV from the parser's cells, normalised to the header column count so
    // it always matches the rendered grid.
    final tsv = rows.map((r) {
      final cells = r.$1;
      return [
        for (var i = 0; i < cols; i++)
          _cellText(i < cells.length ? cells[i] : null)
      ].join('\t');
    }).join('\n');

    final tableRows = <TableRow>[
      for (final (cells, isHeader) in rows)
        TableRow(
          decoration: isHeader
              ? BoxDecoration(color: cs.surfaceContainerHighest)
              : null,
          children: [
            for (var i = 0; i < cols; i++)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: RichText(
                  textAlign:
                      i < cells.length ? _align(cells[i]) : TextAlign.left,
                  text: TextSpan(
                    children: i < cells.length
                        ? _spans(
                            cells[i].children,
                            base.copyWith(
                                fontWeight: isHeader ? FontWeight.bold : null))
                        : const [],
                  ),
                ),
              ),
          ],
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CopyTableChip(tsv: tsv),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: cs.outlineVariant),
            children: tableRows,
          ),
        ),
      ],
    );
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
