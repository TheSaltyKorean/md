import 'dart:convert';

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
    this.highlightQuery,
    this.highlightCaseSensitive = false,
    this.highlightWholeWord = false,
    this.currentMatch = 0,
    this.currentMatchKey,
    this.onMatchCount,
  });

  final String markdown;
  final EdgeInsets padding;

  /// Optional external scroll controller (used by the split view to keep the
  /// preview in sync with the source editor).
  final ScrollController? controller;

  /// Find-in-preview: when non-empty, occurrences of this query are highlighted
  /// in the rendered output (the [currentMatch]th one emphasized), so find
  /// works without leaving Preview.
  final String? highlightQuery;
  final bool highlightCaseSensitive;
  final bool highlightWholeWord;

  /// Zero-based index of the match to emphasize (and key for scroll-to).
  final int currentMatch;

  /// Attached to the current match's widget so the find bar can scroll it into
  /// view via [Scrollable.ensureVisible].
  final GlobalKey? currentMatchKey;

  /// Reports the number of matches actually highlighted in the render — the
  /// authoritative count (it excludes code/link-target text the highlighter
  /// can't mark), so the find bar's "n/N" agrees with what's on screen.
  final ValueChanged<int>? onMatchCount;

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
    final cs = theme.colorScheme;
    final styleSheet = _styleSheet(theme);
    // Base custom builders shared by both render paths.
    final baseBuilders = <String, MarkdownElementBuilder>{
      // flutter_markdown_plus doesn't handle inline HTML, so <u>…</u> is parsed
      // ourselves and rendered underlined (matches the PDF export).
      'u': _UnderlineElementBuilder(),
      // Fenced code block with a copy button (wrapped in codeblockDecoration).
      'pre': _CodeBlockBuilder(theme),
      // The injected "Copy table" chip (inline, so it doesn't grow the package's
      // block-tag registry the way a block builder would).
      'copytable': _CopyTableChipBuilder(),
    };

    final query = highlightQuery;
    if (query != null && query.isNotEmpty) {
      // Find is active: render via the AST-transforming highlighter so matches
      // are marked AFTER the markdown resolves (emphasis / links / underline
      // stay intact, code isn't touched, the count is what's actually marked).
      return SelectionArea(
        child: _HighlightedMarkdown(
          markdown: markdown,
          query: query,
          caseSensitive: highlightCaseSensitive,
          wholeWord: highlightWholeWord,
          current: currentMatch,
          currentKey: currentMatchKey,
          onCount: onMatchCount,
          controller: controller,
          padding: padding,
          styleSheet: styleSheet,
          builders: {
            ...baseBuilders,
            'mark': _HighlightElementBuilder(
              current: currentMatch,
              currentKey: currentMatchKey,
              matchColor: cs.primary.withValues(alpha: 0.22),
              currentColor: cs.tertiary.withValues(alpha: 0.55),
            ),
          },
          onTapLink: _launch,
        ),
      );
    }

    return SelectionArea(
      child: Markdown(
        data: markdown,
        controller: controller,
        // SelectionArea provides selection for the whole document; the widget's
        // own per-block SelectableText would nest inside it and assert.
        selectable: false,
        padding: padding,
        // The real GFM parser identifies tables; we wrap each one with a "Copy
        // table" chip but let the PACKAGE render the table itself — see
        // _CopyableTableSyntax.
        blockSyntaxes: [_CopyableTableSyntax()],
        inlineSyntaxes: [_UnderlineSyntax()],
        builders: baseBuilders,
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

/// Renders Markdown with find-match highlighting done at the AST level: it
/// parses the source the same way the package's [Markdown] widget does, then —
/// AFTER inline elements (emphasis, links, `<u>`, code) are resolved — walks
/// the tree and wraps query matches in visible text with numbered `mark`
/// elements. Because the transform runs post-parse, it never breaks markdown
/// (a `*` query can't disturb `**bold**`), reaches text inside links/underline,
/// keeps link tap recognizers (the `mark` stays nested inside the `a`), and
/// leaves code untouched. The count reported is exactly what's marked, so the
/// find bar's "n/N" can't show a phantom. The transformed AST is cached, so
/// navigating matches only re-builds widgets (no re-parse).
class _HighlightedMarkdown extends StatefulWidget {
  const _HighlightedMarkdown({
    required this.markdown,
    required this.query,
    required this.caseSensitive,
    required this.wholeWord,
    required this.current,
    required this.currentKey,
    required this.onCount,
    required this.controller,
    required this.padding,
    required this.styleSheet,
    required this.builders,
    required this.onTapLink,
  });

  final String markdown;
  final String query;
  final bool caseSensitive;
  final bool wholeWord;
  final int current;
  final GlobalKey? currentKey;
  final ValueChanged<int>? onCount;
  final ScrollController? controller;
  final EdgeInsets padding;
  final MarkdownStyleSheet styleSheet;
  final Map<String, MarkdownElementBuilder> builders;
  final Future<void> Function(String href) onTapLink;

  @override
  State<_HighlightedMarkdown> createState() => _HighlightedMarkdownState();
}

class _HighlightedMarkdownState extends State<_HighlightedMarkdown>
    implements MarkdownBuilderDelegate {
  final _recognizers = <GestureRecognizer>[];
  List<md.Node> _nodes = const [];
  int _count = 0;
  String? _cacheKey;

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  void _clearRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  /// Re-parse + re-transform only when the source or query/options change (not
  /// on navigation), then report the true match count once per change.
  void _rebuildNodes() {
    final key = '${widget.markdown} ${widget.query} '
        '${widget.caseSensitive} ${widget.wholeWord}';
    if (key == _cacheKey) return;
    _cacheKey = key;

    final doc = md.Document(
      blockSyntaxes: [_CopyableTableSyntax()],
      inlineSyntaxes: [_UnderlineSyntax()],
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final ast = doc.parseLines(const LineSplitter().convert(widget.markdown));

    final body = RegExp.escape(widget.query);
    // Same whole-word form as TextSearch (non-word lookarounds), so "C++"
    // matches as a whole word.
    final re = RegExp(widget.wholeWord ? '(?<![\\w])(?:$body)(?![\\w])' : body,
        caseSensitive: widget.caseSensitive, multiLine: true);

    var counter = 0;
    List<md.Node> transform(List<md.Node> nodes) {
      final out = <md.Node>[];
      for (final n in nodes) {
        if (n is md.Text) {
          final text = n.text;
          final matches =
              re.allMatches(text).where((m) => m.end > m.start).toList();
          if (matches.isEmpty) {
            out.add(n);
            continue;
          }
          var last = 0;
          for (final m in matches) {
            if (m.start > last) out.add(md.Text(text.substring(last, m.start)));
            out.add(md.Element.text('mark', m[0]!)
              ..attributes['data-i'] = '${counter++}');
            last = m.end;
          }
          if (last < text.length) out.add(md.Text(text.substring(last)));
        } else if (n is md.Element) {
          final children = n.children;
          // Code renders its text directly (not highlighted); leave it whole.
          if (children == null || n.tag == 'code' || n.tag == 'pre') {
            out.add(n);
          } else {
            out.add(md.Element(n.tag, transform(children))
              ..attributes.addAll(n.attributes));
          }
        } else {
          out.add(n);
        }
      }
      return out;
    }

    _nodes = transform(ast);
    _count = counter;
    final cb = widget.onCount;
    if (cb != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => cb(_count));
    }
  }

  @override
  Widget build(BuildContext context) {
    _rebuildNodes();
    // createLink is called during build() below; drop the previous frame's
    // recognizers first so they don't leak.
    _clearRecognizers();
    final builder = MarkdownBuilder(
      delegate: this,
      selectable: false,
      styleSheet: widget.styleSheet,
      imageDirectory: null,
      imageBuilder: null,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: widget.builders,
      paddingBuilders: const {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    );
    final children = builder.build(_nodes);
    return SingleChildScrollView(
      controller: widget.controller,
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  // --- MarkdownBuilderDelegate ------------------------------------------------

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        if (href != null) widget.onTapLink(href);
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
      style: styleSheet.code, text: code.replaceAll(RegExp(r'\n$'), ''));
}

/// Paints a highlight behind a matched `mark` run (a background on the text
/// style, so it flows inline and wraps like normal text). The current match
/// gets a stronger colour and, if provided, the scroll-to key.
class _HighlightElementBuilder extends MarkdownElementBuilder {
  _HighlightElementBuilder({
    required this.current,
    required this.currentKey,
    required this.matchColor,
    required this.currentColor,
  });

  final int current;
  final GlobalKey? currentKey;
  final Color matchColor;
  final Color currentColor;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final isCurrent =
        int.tryParse(element.attributes['data-i'] ?? '') == current;
    final text = Text(
      element.textContent,
      style: (parentStyle ?? preferredStyle ?? const TextStyle()).copyWith(
          background: Paint()..color = isCurrent ? currentColor : matchColor),
    );
    return isCurrent && currentKey != null
        ? KeyedSubtree(key: currentKey, child: text)
        : text;
  }
}
