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
  final needle = _collapse(selectedText);
  if (needle.isEmpty) return null;

  final doc = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
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
  for (var b = 0; b < blockText.length; b++) {
    final raw = blockText[b];
    var prevSpace = collapsed.isEmpty; // trim leading space of the stream
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
    // fuse onto this one for matching.
    if (b < blockText.length - 1 && collapsed.isNotEmpty) {
      collapsed.write(' ');
      blockOf.add(b);
      offsetOf.add(raw.length);
      prevSpace = true;
    }
  }

  final stream = collapsed.toString();
  final at = stream.indexOf(needle);
  if (at < 0) return null;
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
        if (c.pos >= lo && c.pos < hi) out.add(n);
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
      return '${_inlineToMarkdown(kids)}\n\n';
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
      // <pre><code>…</code></pre>
      final code = kids.isNotEmpty ? _renderedText(kids.first) : '';
      return '```\n${code.trimRight()}\n```\n\n';
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
  var i = 1;
  for (final item in list.children ?? const []) {
    if (item is! md.Element || item.tag != 'li') continue;
    final marker = ordered ? '${i++}. ' : '- ';
    // A list item may hold inline text and/or nested blocks.
    final content = _listItemContent(item.children ?? const []);
    final lines = content.trimRight().split('\n');
    out.writeln('$marker${lines.first}');
    for (final l in lines.skip(1)) {
      out.writeln('  $l'); // continuation lines indented under the marker
    }
  }
  return out.toString();
}

String _listItemContent(List<md.Node> kids) {
  // Loose list items wrap text in <p>; tight ones hold inline nodes directly.
  final hasBlocks = kids.any((n) => n is md.Element && _isBlock(n.tag));
  if (!hasBlocks) return _inlineToMarkdown(kids);
  return _toMarkdown(kids).trimRight();
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
      out.write(n.text);
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
          out.write('`${_renderedText(n)}`');
        case 'a':
          final href = n.attributes['href'] ?? '';
          out.write('[${_inlineToMarkdown(kids)}]($href)');
        case 'img':
          final src = n.attributes['src'] ?? '';
          final alt = n.attributes['alt'] ?? '';
          out.write('![$alt]($src)');
        case 'br':
          out.write('\n');
        default:
          out.write(_inlineToMarkdown(kids)); // u, sub, sup, … → text
      }
    }
  }
  return out.toString();
}

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

class _Counter {
  int pos = 0;
}
