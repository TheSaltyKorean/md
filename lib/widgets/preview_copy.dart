import 'dart:convert';
import 'dart:math' as math;

import 'package:markdown/markdown.dart' as md;

/// Copy-with-formatting for the read-only Preview.
///
/// The Preview renders Markdown through a Flutter `SelectionArea`, which only
/// ever exposes the PLAIN TEXT of a selection — there's no rich form of an
/// arbitrary highlighted range. So to copy formatting we map the selected text
/// back onto the document's Markdown AST and rebuild just that slice, then emit
/// both a Markdown source flavor and an HTML flavor for the clipboard.
///
/// Granularity: within a paragraph or heading the slice is character-precise;
/// container blocks (lists, quotes, tables, code, rules) that the selection
/// touches are included whole (keeping their formatting) rather than split.
/// When the selection can't be located (e.g. it spans content the renderer
/// shows differently), the caller falls back to copying plain text.

/// Leaf blocks whose inline text can be trimmed to an exact character range.
const _trimmableBlocks = {'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// Inline tags that contribute their children's text to the same rendered line.
const _inlineTags = {'em', 'strong', 'a', 'del', 'u', 'sub', 'sup'};

/// The Markdown + HTML renditions of [selectedText] (the plain text the Preview
/// selection produced) within [source], or null when it can't be located — the
/// caller then copies plain text unchanged.
({String markdown, String html})? previewSelectionFormats(
    String source, String selectedText) {
  final rawNeedle = _collapse(selectedText);
  if (rawNeedle.isEmpty) return null;

  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // Parse the toolbar's underline markup like PreviewView does, so a
    // selection inside <u>…</u> maps to a real element (not raw tag text) and
    // keeps its underline in the copy.
    inlineSyntaxes: [_UnderlineSyntax()],
    encodeHtml: false,
  );
  final blocks = doc.parseLines(const LineSplitter().convert(source));
  if (blocks.isEmpty) return null;

  // Rendered text of each top-level block, and a whitespace-collapsed stream of
  // the whole document with a map from each collapsed char back to (block,
  // offset-within-block) so a match can be resolved to block boundaries.
  final blockText = blocks.map(_renderedText).toList();
  final collapsed = StringBuffer();
  final blockOf = <int>[]; // collapsed index -> block index
  final offsetOf = <int>[]; // collapsed index -> raw offset within that block
  // prevSpace persists ACROSS blocks so a rendered-empty block (a rule, an
  // image-only paragraph) between text blocks doesn't emit a second collapsed
  // space that the actual selection wouldn't have.
  var prevSpace = true; // also trims the stream's leading space
  for (var b = 0; b < blockText.length; b++) {
    final raw = blockText[b];
    for (var i = 0; i < raw.length; i++) {
      final isSpace = _isSpace(raw[i]);
      if (isSpace) {
        if (prevSpace) continue;
        collapsed.write(' ');
        blockOf.add(b);
        offsetOf.add(i);
        prevSpace = true;
      } else {
        collapsed.write(raw[i]);
        blockOf.add(b);
        offsetOf.add(i);
        prevSpace = false;
      }
    }
    // A block boundary is whitespace in the render, so the next block can't
    // fuse onto this one — but only one space, even across empty blocks.
    if (b < blockText.length - 1 && !prevSpace) {
      collapsed.write(' ');
      blockOf.add(b);
      offsetOf.add(raw.length);
      prevSpace = true;
    }
  }

  final stream = collapsed.toString();
  // The selection could be literal (as-is, e.g. a paragraph "1. Install") or a
  // list row selected with its rendered marker (marker-less "Install"). Prefer
  // the as-is match; only fall back to the stripped form when the raw form
  // doesn't match at all.
  final rawAt = _uniqueIndexOf(stream, rawNeedle);
  final strippedNeedle = _collapse(_stripListMarkers(selectedText));
  final int at;
  final String needle;
  if (rawAt != null) {
    // If the marker-less form of the selection ALSO appears in a different
    // block, the marker text is genuinely ambiguous (literal vs a real list
    // row) — fall back to plain text rather than pick the wrong range.
    if (strippedNeedle.isNotEmpty && strippedNeedle != rawNeedle) {
      final rawBlock = blockOf[rawAt];
      for (var i = stream.indexOf(strippedNeedle);
          i >= 0;
          i = stream.indexOf(strippedNeedle, i + 1)) {
        if (blockOf[i] != rawBlock) return null;
      }
    }
    at = rawAt;
    needle = rawNeedle;
  } else {
    if (strippedNeedle.isEmpty || strippedNeedle == rawNeedle) return null;
    final strippedAt = _uniqueIndexOf(stream, strippedNeedle);
    if (strippedAt == null) return null;
    at = strippedAt;
    needle = strippedNeedle;
  }
  final end = at + needle.length - 1; // inclusive last matched char

  final firstBlock = blockOf[at];
  final lastBlock = blockOf[end];
  final startOffset = offsetOf[at];
  final endOffset = offsetOf[end] + 1; // exclusive

  final selected = <md.Node>[];
  for (var b = firstBlock; b <= lastBlock; b++) {
    final node = blocks[b];
    final lo = b == firstBlock ? startOffset : 0;
    final hi = b == lastBlock ? endOffset : blockText[b].length;
    if (node is md.Element &&
        _trimmableBlocks.contains(node.tag) &&
        !(lo == 0 && hi >= blockText[b].length)) {
      final trimmed = _trimBlock(node, lo, hi);
      if (trimmed != null) selected.add(trimmed);
    } else {
      selected.add(node); // whole block (container, or fully covered)
    }
  }
  if (selected.isEmpty) return null;

  final markdown = _toMarkdown(selected).trim();
  final html = md.renderToHtml(selected).trim();
  if (markdown.isEmpty && html.isEmpty) return null;
  return (markdown: markdown, html: html);
}

/// The visible text a node renders as. Inline siblings concatenate directly
/// (their spaces already live in the text); a space is inserted only around a
/// BLOCK-level child, since blocks render on separate lines and mustn't fuse.
String _renderedText(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is md.Element) {
    final children = node.children;
    if (children == null) return node.tag == 'br' ? ' ' : '';
    final buf = StringBuffer();
    for (var i = 0; i < children.length; i++) {
      if (i > 0 &&
          (_isBlockNode(children[i - 1]) || _isBlockNode(children[i]))) {
        buf.write(' ');
      }
      buf.write(_renderedText(children[i]));
    }
    return buf.toString();
  }
  return '';
}

/// Whether [n] is a block-level element (renders on its own line). Text and
/// inline elements (emphasis, links, code, br, img) are not.
bool _isBlockNode(md.Node n) =>
    n is md.Element &&
    !_inlineTags.contains(n.tag) &&
    n.tag != 'code' &&
    n.tag != 'br' &&
    n.tag != 'img';

/// A clone of leaf block [block] keeping only inline content in the rendered
/// offset range [lo, hi).
md.Element? _trimBlock(md.Element block, int lo, int hi) {
  final counter = _Counter();
  final kept = _trimInline(block.children ?? const [], lo, hi, counter);
  if (kept.isEmpty) return null;
  return md.Element(block.tag, kept)..attributes.addAll(block.attributes);
}

/// Keep only the parts of [nodes] whose rendered offsets fall in [lo, hi),
/// trimming partially-covered text and recursing into inline elements.
List<md.Node> _trimInline(List<md.Node> nodes, int lo, int hi, _Counter c) {
  final out = <md.Node>[];
  for (final n in nodes) {
    if (c.pos >= hi) break;
    if (n is md.Text) {
      final start = c.pos;
      c.pos += n.text.length;
      final s = math.max(lo, start);
      final e = math.min(hi, c.pos);
      if (s < e) out.add(md.Text(n.text.substring(s - start, e - start)));
    } else if (n is md.Element) {
      final children = n.children;
      if (children == null) {
        // A leaf element (e.g. <br>, <img>) still occupies its rendered width,
        // so advance the counter by that width or later text slices one char
        // early. Include it when its position falls in range.
        final start = c.pos;
        c.pos += _renderedText(n).length;
        if (start >= lo && start < hi) out.add(n);
        continue;
      }
      final kept = _trimInline(children, lo, hi, c);
      if (kept.isNotEmpty) {
        out.add(md.Element(n.tag, kept)..attributes.addAll(n.attributes));
      }
    }
  }
  return out;
}

/// Serialize a slice of the Markdown AST back to Markdown source. Covers the
/// common blocks/inlines; the HTML flavor (via renderToHtml) is authoritative
/// for anything this doesn't render precisely.
String _toMarkdown(List<md.Node> nodes) {
  final out = StringBuffer();
  for (final node in nodes) {
    out.write(_blockToMarkdown(node));
  }
  return out.toString();
}

String _blockToMarkdown(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is! md.Element) return '';
  final tag = node.tag;
  final kids = node.children ?? const [];
  switch (tag) {
    case 'p':
      return '${_escapeBlockStart(_inlineToMarkdown(kids))}\n\n';
    case 'h1':
    case 'h2':
    case 'h3':
    case 'h4':
    case 'h5':
    case 'h6':
      final level = int.parse(tag.substring(1));
      return '${'#' * level} ${_inlineToMarkdown(kids)}\n\n';
    case 'blockquote':
      final inner = _toMarkdown(kids).trimRight();
      final quoted =
          inner.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');
      return '$quoted\n\n';
    case 'ul':
      return '${_listToMarkdown(node, ordered: false)}\n';
    case 'ol':
      return '${_listToMarkdown(node, ordered: true)}\n';
    case 'pre':
      // <pre><code>…</code></pre>. Use a fence longer than any backtick run in
      // the code so a block that itself shows ``` doesn't close early. Strip
      // only the parser-added final newline — code whitespace is significant.
      var code = kids.isNotEmpty ? _renderedText(kids.first) : '';
      if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
      final fence = _backtickFence(code);
      return '$fence\n$code\n$fence\n\n';
    case 'hr':
      return '---\n\n';
    default:
      // Unknown/complex block (e.g. a table): fall back to its HTML so the
      // Markdown flavor at least carries it verbatim.
      return '${md.renderToHtml([node]).trim()}\n\n';
  }
}

String _listToMarkdown(md.Element list, {required bool ordered}) {
  final out = StringBuffer();
  // An ordered list can start at a value other than 1 (the parser records it in
  // the `start` attribute) — keep the visible numbering.
  var i = ordered ? (int.tryParse(list.attributes['start'] ?? '') ?? 1) : 1;
  for (final item in list.children ?? const []) {
    if (item is! md.Element || item.tag != 'li') continue;
    final marker = ordered ? '${i++}. ' : '- ';
    final indent = ' ' * marker.length; // align continuations to the content
    final content = _listItemContent(item.children ?? const []);
    final lines = content.trimRight().split('\n');
    out.writeln('$marker${lines.first}');
    for (final l in lines.skip(1)) {
      // Keep blank lines (loose-list paragraph breaks) truly blank.
      out.writeln(l.isEmpty ? '' : '$indent$l');
    }
  }
  return out.toString();
}

String _listItemContent(List<md.Node> kids) {
  // Loose list items wrap text in <p>; tight ones hold inline nodes directly,
  // possibly followed by a nested list. Separate the leading inline run from
  // block children with a newline so a nested list doesn't fuse onto the item's
  // text (which _listToMarkdown then indents as continuation lines).
  final inlineLead = <md.Node>[];
  final blocks = <md.Node>[];
  var seenBlock = false;
  for (final n in kids) {
    if (!seenBlock && !(n is md.Element && _isBlock(n.tag))) {
      inlineLead.add(n);
    } else {
      seenBlock = true;
      blocks.add(n);
    }
  }
  final buf = StringBuffer();
  // Escape a block marker at the start of the item's text (e.g. a literal
  // "# not a heading") so it doesn't re-parse as a heading/nested list after
  // the item's own marker.
  if (inlineLead.isNotEmpty) {
    buf.write(_escapeBlockStart(_inlineToMarkdown(inlineLead)));
  }
  for (final b in blocks) {
    if (buf.isNotEmpty) {
      // A nested list follows directly; a loose paragraph needs a blank line so
      // it doesn't collapse into a soft break.
      final tight = b is md.Element && (b.tag == 'ul' || b.tag == 'ol');
      buf.write(tight ? '\n' : '\n\n');
    }
    buf.write(_blockToMarkdown(b).trimRight());
  }
  return buf.toString();
}

/// A fence of backticks longer than any run inside [code] (min 3), so a fenced
/// code block containing ``` doesn't terminate early.
String _backtickFence(String code) {
  var maxRun = 0;
  for (final m in RegExp('`+').allMatches(code)) {
    maxRun = math.max(maxRun, m.group(0)!.length);
  }
  return '`' * math.max(3, maxRun + 1);
}

/// Wrap inline [code] in a backtick run longer than any inside it, padding with
/// a space when it starts/ends with a backtick (CommonMark inline-code rules).
String _inlineCode(String code) {
  var maxRun = 0;
  for (final m in RegExp('`+').allMatches(code)) {
    maxRun = math.max(maxRun, m.group(0)!.length);
  }
  final delim = '`' * (maxRun + 1);
  // Pad when the code starts/ends with a backtick OR a space: CommonMark strips
  // one leading+trailing space from a padded span, so the extra space we add is
  // consumed and the code's own spaces survive.
  final pad = (code.startsWith('`') ||
          code.endsWith('`') ||
          code.startsWith(' ') ||
          code.endsWith(' '))
      ? ' '
      : '';
  return '$delim$pad$code$pad$delim';
}

/// Angle-bracket a link destination that contains whitespace or parentheses so
/// it parses as a single destination; escape any `<`/`>`/`\` inside.
String _linkDestination(String href) {
  if (!RegExp(r'[\s()<>]').hasMatch(href)) return href;
  final escaped = href
      .replaceAll(r'\', r'\\')
      .replaceAll('<', r'\<')
      .replaceAll('>', r'\>');
  return '<$escaped>';
}

/// Escape a leading block marker (`#`, `>`, `-`/`+` bullet, `N.`/`N)` ordered)
/// so a literal paragraph doesn't re-parse as a heading/quote/list.
/// Escape block markers at the start of EVERY line (a paragraph can contain
/// hard/soft breaks), so no line re-parses as a heading/quote/list/rule.
String _escapeBlockStart(String s) =>
    s.split('\n').map(_escapeLineStart).join('\n');

String _escapeLineStart(String s) {
  if (s.isEmpty) return s;
  final ol = RegExp(r'^(\d+)([.)])(\s|$)').firstMatch(s);
  if (ol != null) {
    return '${ol.group(1)}\\${ol.group(2)}${s.substring(ol.end - ol.group(3)!.length)}';
  }
  // A thematic break (---, ***, ___, or spaced like `- - -`). *** / ___ already
  // get their chars escaped inline, so this mainly catches leading `---`.
  if (RegExp(r'^ {0,3}([-*_])( *\1){2,} *$').hasMatch(s)) {
    return '\\$s';
  }
  if (RegExp(r'^#{1,6}(\s|$)').hasMatch(s) ||
      s.startsWith('>') ||
      RegExp(r'^[-+]\s').hasMatch(s)) {
    return '\\$s';
  }
  return s;
}

/// Remove rendered list markers (bullets and line-start ordered numbers) from a
/// selection before matching — they're painted chrome, not AST text.
String _stripListMarkers(String s) {
  final noBullets = s.replaceAll('•', ' ');
  // "1. " / "1) " at the start of a line (how the Preview renders ordered
  // markers); keep the line break so items stay separated.
  return noBullets.replaceAllMapped(
      RegExp(r'(^|[\n\r])[ \t]*\d+[.)][ \t]+'), (m) => m.group(1)!);
}

bool _isBlock(String tag) =>
    tag == 'p' ||
    tag == 'ul' ||
    tag == 'ol' ||
    tag == 'blockquote' ||
    tag == 'pre' ||
    tag.startsWith('h') && tag.length == 2;

String _inlineToMarkdown(List<md.Node> nodes) {
  final out = StringBuffer();
  for (final n in nodes) {
    if (n is md.Text) {
      // Escape source that shows literally (e.g. \*not italic\*) so it doesn't
      // re-parse as formatting when pasted into another Markdown editor.
      out.write(_escapeMarkdown(n.text));
    } else if (n is md.Element) {
      final kids = n.children ?? const [];
      switch (n.tag) {
        case 'strong':
          out.write('**${_inlineToMarkdown(kids)}**');
        case 'em':
          out.write('*${_inlineToMarkdown(kids)}*');
        case 'del':
          out.write('~~${_inlineToMarkdown(kids)}~~');
        case 'code':
          out.write(_inlineCode(_renderedText(n)));
        case 'a':
          final href = _linkDestination(n.attributes['href'] ?? '');
          out.write('[${_inlineToMarkdown(kids)}]($href)');
        case 'img':
          final src = _linkDestination(n.attributes['src'] ?? '');
          final alt = _escapeMarkdown(n.attributes['alt'] ?? '');
          out.write('![$alt]($src)');
        case 'u':
          // The <u> syntax captures its contents as LITERAL text, so emit the
          // raw text (no Markdown escaping) — escapes would paste back verbatim.
          out.write('<u>${_renderedText(n)}</u>'); // toolbar underline
        case 'br':
          out.write('  \n'); // two trailing spaces => a hard break survives
        case 'input':
          // GFM task-list checkbox: keep the checked/unchecked state. Checked
          // items are marked by the attribute's PRESENCE (matching the PDF
          // path); its value isn't guaranteed to be 'true'.
          final checked = n.attributes.containsKey('checked') &&
              n.attributes['checked'] != 'false';
          out.write(checked ? '[x] ' : '[ ] ');
        default:
          out.write(_inlineToMarkdown(kids)); // sub, sup, … → text
      }
    }
  }
  return out.toString();
}

/// Escape the inline Markdown metacharacters in literal text so pasted Markdown
/// renders the same characters rather than re-interpreting them as syntax.
String _escapeMarkdown(String text) =>
    text.replaceAllMapped(RegExp(r'[\\`*_\[\]<>~&]'), (m) => '\\${m[0]}');

/// Collapse all whitespace runs to a single space and trim — the form used to
/// locate the selection in the rendered stream (robust to how the renderer and
/// the selection layer differ on spacing/newlines).
String _collapse(String s) {
  final out = StringBuffer();
  var prevSpace = true;
  for (var i = 0; i < s.length; i++) {
    if (_isSpace(s[i])) {
      if (!prevSpace) {
        out.write(' ');
        prevSpace = true;
      }
    } else {
      out.write(s[i]);
      prevSpace = false;
    }
  }
  return out.toString().trim();
}

bool _isSpace(String ch) => ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r';

/// Index of [needle] in [stream] iff it occurs exactly once — a duplicated
/// selection can't be resolved to a definite (formatted) range.
int? _uniqueIndexOf(String stream, String needle) {
  final at = stream.indexOf(needle);
  if (at < 0 || stream.indexOf(needle, at + 1) >= 0) return null;
  return at;
}

class _Counter {
  int pos = 0;
}

/// Parses the app's `<u>…</u>` underline markup into a `u` element, matching
/// PreviewView so a copied selection keeps its underline.
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax() : super(r'<u>([\s\S]*?)</u>');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match[1] ?? ''));
    return true;
  }
}
