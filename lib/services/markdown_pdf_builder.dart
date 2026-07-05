import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/print_profile.dart';

/// Parses `<u>…</u>` inline HTML into a `u` element so the PDF renderer can
/// underline it (package:markdown otherwise leaves the raw tags as text).
class _UnderlineSyntax extends md.InlineSyntax {
  _UnderlineSyntax() : super(r'<u>([\s\S]*?)</u>');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('u', match[1] ?? ''));
    return true;
  }
}

/// A bundle of fonts (regular/bold/italic/mono) used to render a PDF.
class PdfFontSet {
  const PdfFontSet({
    required this.base,
    required this.bold,
    required this.italic,
    required this.boldItalic,
    required this.mono,
  });

  final pw.Font base;
  final pw.Font bold;
  final pw.Font italic;
  final pw.Font boldItalic;
  final pw.Font mono;
}

/// Converts a Markdown string into a list of `pdf` package widgets, styled
/// according to a [PrintProfile]. The widgets are designed to be dropped into a
/// [pw.MultiPage] so headers/footers/watermarks are applied by the caller.
class MarkdownPdfBuilder {
  MarkdownPdfBuilder(
      {required this.profile, required this.fonts, this.baseDir});

  final PrintProfile profile;
  final PdfFontSet fonts;

  /// Directory of the source document, used to resolve relative image paths.
  final String? baseDir;

  PdfColor get _primary => PdfColor.fromInt(profile.primaryColor);
  PdfColor get _text => PdfColor.fromInt(profile.textColor);
  PdfColor get _accent =>
      PdfColor.fromInt(profile.accentColor ?? profile.primaryColor);

  /// The brand colour for headings and body chrome (heading rules, blockquote
  /// bars, table header fills). In [PrintProfile.legalMode] this drops the brand
  /// colour and uses the body text colour instead, so the whole document —
  /// including quotes and tables — prints monochrome (court output).
  PdfColor get _brandColor => profile.legalMode ? _text : _primary;

  /// First-line paragraph indent in PDF points (0 when disabled). The `pdf`
  /// package has no native first-line indent, so we emulate it by prepending a
  /// fixed-width [pw.WidgetSpan] spacer to the paragraph's first line — it wraps
  /// and justifies like any other span (see [_bodyRich]).
  double get _firstLineIndentPt =>
      profile.firstLineIndentIn <= 0 ? 0 : profile.firstLineIndentIn * 72.0;

  /// Extra inter-line leading (pt) for a run at [size], derived from the
  /// profile's line-spacing multiple. 1.0 keeps the historical 2.5pt base
  /// leading; larger multiples add `size × (multiple − 1)` on top (so 2.0 ≈
  /// double spacing). Never negative.
  double _leadingFor(double size) {
    const base = 2.5;
    final extra = size * (profile.lineSpacingMultiple - 1.0);
    final v = base + extra;
    return v < 0 ? 0 : v;
  }

  /// Bottom gap after a body-level block (paragraph, list item, heading,
  /// quote). Court/manuscript documents are *uniformly* spaced: the gap after
  /// a paragraph must continue the in-paragraph line rhythm, so the
  /// baseline-to-baseline distance across a paragraph break equals the spaced
  /// line height. Within a paragraph that distance is line-height +
  /// [_leadingFor]; across a break it is line-height + bottom padding — so the
  /// padding must equal the leading itself (≈13.5pt for 11pt double-spaced;
  /// using the full `size × multiple` here would double-count the line box and
  /// open a visibly larger gap at every break). Non-legal documents keep the
  /// historical fixed 8pt so existing output is unchanged.
  double get _blockGap => profile.legalMode ? _leadingFor(11.0) : 8.0;

  List<pw.Widget> build(String markdown) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
      // The toolbar / AppFlowy round-trip emit <u>…</u>; package:markdown leaves
      // inline HTML as text, so parse it into a 'u' element ourselves.
      inlineSyntaxes: [_UnderlineSyntax()],
    );
    final nodes = document.parseLines(const LineSplitter().convert(markdown));
    return nodes.expand(_emit).toList();
  }

  /// Emit the widgets for one block-level node. Raw-HTML blocks are scanned
  /// for standalone page-break directives and split around them, so every
  /// [pw.NewPage] lands at the top level of the returned list —
  /// [pw.MultiPage] ignores a NewPage nested inside a column. The scan
  /// matters because package:markdown keeps *adjacent* HTML lines in a single
  /// text node, so a break div may share its block with other divs (e.g. a
  /// break directly above a caption). Blocks without a directive take the
  /// unchanged [_block] path.
  Iterable<pw.Widget> _emit(md.Node node) sync* {
    final raw = _rawHtmlText(node);
    if (raw != null && _findPageBreak(raw) != null) {
      var rest = raw;
      for (var m = _findPageBreak(rest); m != null; m = _findPageBreak(rest)) {
        final before = rest.substring(0, m.start).trim();
        if (before.isNotEmpty) {
          yield _divBlock(before) ?? _paragraph([md.Text(before)]);
        }
        // The element may be visible in its own right (a signature line that
        // also carries the directive): render it on the side of the break its
        // directive names, so `…-before` breaks first and then draws it.
        final style = _breakStyleOf(m);
        final rendered = _divBlock(m.group(0)!);
        final visible = rendered != null && rendered is! pw.SizedBox;
        if (_breakValue(style, before: true)) yield pw.NewPage();
        if (visible) yield rendered;
        if (_breakValue(style, before: false)) yield pw.NewPage();
        rest = rest.substring(m.end);
      }
      final tail = rest.trim();
      if (tail.isNotEmpty) {
        yield _divBlock(tail) ?? _paragraph([md.Text(tail)]);
      }
      return;
    }
    final w = _block(node);
    if (w != null) yield w;
  }

  /// The raw text of a block package:markdown left as HTML — a text node, or
  /// a paragraph whose children are pure text (the same guard [_block] uses so
  /// inline-code samples are never treated as markup). Null otherwise.
  String? _rawHtmlText(md.Node node) {
    if (node is md.Text) return node.text;
    if (node is md.Element && node.tag == 'p') {
      final pc = node.children ?? const <md.Node>[];
      if (pc.isNotEmpty && pc.every((c) => c is md.Text)) {
        return node.textContent;
      }
    }
    return null;
  }

  // --- Inline-styled <div> blocks (signature lines & labels) ------------------

  static final _divOpen = RegExp(r'<div\b([^>]*)>', caseSensitive: false);
  static final _divTag = RegExp(r'<(/?)div\b[^>]*>', caseSensitive: false);

  /// If [raw] is block-level `<div>` HTML (used by legal docs for signature
  /// lines and labels), render those divs and any text between them; else null.
  /// Operating on already-parsed block text means fenced code samples (which are
  /// `pre`/`code` nodes) are never mistaken for document divs.
  pw.Widget? _divBlock(String raw) {
    if (!_divOpen.hasMatch(raw)) return null;
    final children = _renderDivSequence(raw);
    if (children.isEmpty) return pw.SizedBox();
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start, children: children),
    );
  }

  /// Render text interleaved with *balanced* `<div>…</div>` blocks (so a wrapper
  /// div containing a signature line + label is handled, not just flat divs).
  /// [inRow] is set when these widgets become children of a `display:flex` row,
  /// so a text block must shrink-wrap (a full-width box would overflow a Row).
  List<pw.Widget> _renderDivSequence(String raw, {bool inRow = false}) {
    final out = <pw.Widget>[];
    void addText(String s) {
      // Text between divs is raw HTML too — normalise <br>, strip tags, decode
      // entities so it doesn't leak literal markup.
      final t = _decodeEntities(s
              .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
              .replaceAll(RegExp(r'<[^>]*>'), ''))
          .trim();
      if (t.isEmpty) return;
      out.add(pw.RichText(text: pw.TextSpan(children: _inline([md.Text(t)]))));
    }

    var i = 0;
    while (i < raw.length) {
      final open = _divOpen.firstMatch(raw.substring(i));
      if (open == null) {
        addText(raw.substring(i));
        break;
      }
      final openAbs = i + open.start;
      addText(raw.substring(i, openAbs));
      final (closeStart, closeEnd) = _matchDiv(raw, openAbs);
      if (closeStart < 0) {
        addText(raw.substring(openAbs).replaceAll(RegExp(r'</?div[^>]*>'), ''));
        break;
      }
      final contentStart = openAbs + open.group(0)!.length;
      final w = _htmlDiv(
          open.group(1) ?? '', raw.substring(contentStart, closeStart),
          inRow: inRow);
      if (w != null) out.add(w);
      i = closeEnd;
    }
    return out;
  }

  /// (start, end) of the `</div>` that closes the `<div>` opening at [openAbs],
  /// or (-1, -1). The end is the real tag end so a spaced `</div >` advances
  /// correctly.
  (int, int) _matchDiv(String s, int openAbs) {
    var depth = 0;
    for (final m in _divTag.allMatches(s, openAbs)) {
      if (m.group(1) == '/') {
        depth--;
        if (depth == 0) return (m.start, m.end);
      } else {
        depth++;
      }
    }
    return (-1, -1);
  }

  /// Render a single `<div style="…">content</div>`. A wrapper div (whose content
  /// holds more divs) recurses into a column — or, with `display:flex`, a row
  /// (the two-column court caption); an empty div with a *visible* `border-bottom`
  /// becomes a signature/blank line; a div with text becomes a styled label
  /// honouring `text-align`. Returns null for an empty, borderless/structural div.
  ///
  /// [inRow] is set when this div is itself a child of a `display:flex` row, so
  /// a text block shrink-wraps rather than stretching to the full width (which
  /// would overflow a [pw.Row]).
  pw.Widget? _htmlDiv(String attrs, String content, {bool inRow = false}) {
    final decls = _styleDecls(attrs);
    if (_divOpen.hasMatch(content)) {
      final style = _parseStyle(attrs);
      // A `display:flex` wrapper lays its child divs out horizontally (a court
      // caption's name-left / role-right row) — unless flex-direction is a
      // column, which stacks (CSS default is row). Anything else is a column.
      final display = (style['display'] ?? '').toLowerCase();
      final dir = (style['flex-direction'] ?? '').trim().toLowerCase();
      final isFlexRow = display.contains('flex') && !dir.startsWith('column');
      // Children of a row must shrink-wrap; propagate that context to nested
      // (even non-flex) wrappers so a grandchild doesn't take the full-width
      // path and overflow the outer Row.
      final inner = _renderDivSequence(content, inRow: isFlexRow || inRow);
      if (inner.isEmpty) return null;
      final pw.Widget layout = isFlexRow
          ? pw.Row(
              mainAxisAlignment: _mainAxis(style['justify-content']),
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: inner,
            )
          : pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start, children: inner);
      // Apply the wrapper div's own vertical spacing around the inner content.
      final mt = _marginPt(decls, 'top');
      final mb = _marginPt(decls, 'bottom');
      return (mt > 0 || mb > 0)
          ? pw.Padding(
              padding: pw.EdgeInsets.only(top: mt, bottom: mb), child: layout)
          : layout;
    }
    final style = _parseStyle(attrs);
    // Inline markup inside a label (<b>…</b>) and HTML whitespace entities are
    // common in exported legal HTML; strip tags and normalise nbsp before
    // deciding whether the div is "empty".
    final stripped = content
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'&nbsp;|&#160;|&#xA0;', caseSensitive: false), ' ')
        .replaceAll(' ', ' ')
        .trim();
    // Decode HTML entities so a label like "AT&amp;T" renders as "AT&T".
    final text = _decodeEntities(stripped);
    // Resolve the effective bottom border (shorthand merged with longhand
    // overrides; null when invisible). Margins honour the shorthand + bottom.
    final border = _resolveBorder(decls);
    final gapTop = _marginPt(decls, 'top');
    final gapBottom = _marginPt(decls, 'bottom');

    if (text.isEmpty) {
      // Invisible border (none/hidden/0-width/transparent): if the div still
      // reserves space, render a spacer so signature gaps aren't collapsed.
      if (border == null) {
        final gap = (_lengthPt(style['height']) ?? 0) + gapTop + gapBottom;
        return gap > 0 ? pw.SizedBox(height: gap) : null;
      }
      final thickness = border.$1 < 0.4 ? 0.4 : border.$1;
      final height = _lengthPt(style['height']) ?? 36;
      final line = pw.Container(height: thickness, color: border.$2);
      // Width may be a percentage (weighted flex) or a fixed length. An explicit
      // fixed width is honoured even when zero (a collapsed/hidden rule).
      final widthPt = _lengthPt(style['width']);
      final widthPct = _percent(style['width']);
      final pw.Widget sized;
      if (widthPt != null && widthPt <= 0) {
        sized = pw.SizedBox(); // explicit 0 => collapsed rule
      } else if (widthPct != null && widthPct <= 0) {
        sized = pw.SizedBox(); // explicit 0% => collapsed rule
      } else if (inRow) {
        // Inside a flex row the rule must be bounded (a full-width or
        // percentage/Expanded rule would overflow the Row): use the explicit
        // width, else a fixed default.
        sized = pw.SizedBox(width: widthPt ?? 108, child: line);
      } else if (widthPt != null) {
        sized = pw.Align(
            alignment: pw.Alignment.centerLeft,
            child: pw.SizedBox(width: widthPt, child: line));
      } else {
        final pct = (widthPct ?? 60).clamp(1.0, 100.0);
        sized = pct >= 99
            ? line
            : pw.Row(children: [
                pw.Expanded(flex: pct.round(), child: line),
                pw.Expanded(
                    flex: (100 - pct).round().clamp(1, 100),
                    child: pw.SizedBox()),
              ]);
      }
      return pw.Padding(
        padding:
            pw.EdgeInsets.only(top: gapTop + height, bottom: gapBottom + 2),
        child: sized,
      );
    }

    final size = _lengthPt(style['font-size']) ?? 10;
    final color = _cssColor(style['color']) ?? _text;
    final align = _textAlign(style['text-align']);
    final textWidget = pw.Text(
      text,
      textAlign: align ?? pw.TextAlign.left,
      style: pw.TextStyle(fontSize: size, color: color, font: fonts.base),
    );
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: gapTop, bottom: gapBottom + 4),
      // An explicit alignment only bites when the text fills the content width;
      // stretch it (unless inside a flex row, where a full-width box would
      // overflow). Unset alignment keeps the original left-aligned shrink-wrap.
      child: (align == null || inRow)
          ? textWidget
          : pw.SizedBox(width: double.infinity, child: textWidget),
    );
  }

  /// Map a CSS `text-align` value to a [pw.TextAlign], or null when unset/unknown
  /// (so the default left shrink-wrap is preserved).
  pw.TextAlign? _textAlign(String? v) {
    switch ((v ?? '').trim().toLowerCase()) {
      case 'center':
        return pw.TextAlign.center;
      case 'right':
      case 'end':
        return pw.TextAlign.right;
      case 'justify':
        return pw.TextAlign.justify;
      case 'left':
      case 'start':
        return pw.TextAlign.left;
      default:
        return null;
    }
  }

  /// Map a CSS `justify-content` value to a [pw.MainAxisAlignment] for a
  /// `display:flex` row (default start).
  pw.MainAxisAlignment _mainAxis(String? v) {
    switch ((v ?? '').trim().toLowerCase()) {
      case 'space-between':
        return pw.MainAxisAlignment.spaceBetween;
      case 'space-around':
        return pw.MainAxisAlignment.spaceAround;
      case 'space-evenly':
        return pw.MainAxisAlignment.spaceEvenly;
      case 'center':
        return pw.MainAxisAlignment.center;
      case 'flex-end':
      case 'end':
      case 'right':
        return pw.MainAxisAlignment.end;
      default:
        return pw.MainAxisAlignment.start;
    }
  }

  /// Declarations from a style attribute, in source order (so shorthand vs
  /// longhand precedence can follow CSS "later wins" rules).
  List<MapEntry<String, String>> _styleDecls(String attrs) {
    final m =
        RegExp(r'''style\s*=\s*("([^"]*)"|'([^']*)')''', caseSensitive: false)
            .firstMatch(attrs);
    final out = <MapEntry<String, String>>[];
    if (m == null) return out;
    for (final decl in (m.group(2) ?? m.group(3) ?? '').split(';')) {
      final i = decl.indexOf(':');
      if (i <= 0) continue;
      out.add(MapEntry(decl.substring(0, i).trim().toLowerCase(),
          decl.substring(i + 1).trim()));
    }
    return out;
  }

  /// Style as a property map (last declaration wins) for simple single-value
  /// lookups like width/height/font-size/color.
  Map<String, String> _parseStyle(String attrs) {
    final out = <String, String>{};
    for (final e in _styleDecls(attrs)) {
      out[e.key] = e.value;
    }
    return out;
  }

  /// Parse a CSS absolute length into points. Supports pt/px/in/cm/mm/pc/q and
  /// em/rem (~12pt). Returns null for unknown or relative units (e.g. %, vh) so
  /// callers don't mistake them for points.
  double? _lengthPt(String? v) {
    if (v == null) return null;
    final m = RegExp(r'(-?[\d.]+)\s*([a-z%]*)', caseSensitive: false)
        .firstMatch(v.trim());
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    switch (m.group(2)!.toLowerCase()) {
      case '':
      case 'pt':
        return n;
      case 'px':
        return n * 0.75;
      case 'in':
        return n * 72;
      case 'cm':
        return n * 28.3465;
      case 'mm':
        return n * 2.83465;
      case 'pc':
        return n * 12;
      case 'q':
        return n * 0.708661;
      case 'em':
      case 'rem':
        return n * 12;
      default:
        return null; // %, vh, vw, etc. — not an absolute length
    }
  }

  double? _percent(String? v) {
    if (v == null) return null;
    final m = RegExp(r'([\d.]+)\s*%').firstMatch(v);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  static const _borderStyles = {
    'solid',
    'dashed',
    'dotted',
    'double',
    'groove',
    'ridge',
    'inset',
    'outset'
  };

  /// The effective bottom border as (widthPt, colour), or null when invisible.
  /// Merges the `border-bottom` shorthand with longhand `border-bottom-*`
  /// overrides (later declaration wins) and follows CSS visibility rules: a
  /// border needs a drawable *style* keyword (a width or colour alone leaves the
  /// style at `none`), a positive width, and a non-transparent colour.
  (double, PdfColor)? _resolveBorder(List<MapEntry<String, String>> decls,
      {PdfColor? currentColor}) {
    double? width;
    String? styleKw;
    PdfColor? color;
    var transparent = false;

    // Walk declarations in source order so a later shorthand overrides an
    // earlier longhand (and vice versa), matching CSS.
    for (final e in decls) {
      switch (e.key) {
        case 'border-bottom':
          // The shorthand resets all components to their initial values, then
          // applies whatever tokens it carries (so a later shorthand that omits
          // the width restores the medium default rather than keeping an earlier
          // border-bottom-width).
          width = null; // initial width = medium (resolved to 1pt below)
          styleKw = 'none'; // initial style
          color = null; // initial colour
          transparent = false;
          final w = _firstBorderWidth(e.value);
          if (w != null) width = w;
          final s = RegExp(
                  r'\b(none|hidden|solid|dashed|dotted|double|groove|ridge|inset|outset)\b',
                  caseSensitive: false)
              .firstMatch(e.value);
          if (s != null) styleKw = s.group(0)!.toLowerCase();
          final c = _cssColor(e.value);
          if (c != null) color = c;
          transparent = _isTransparent(e.value);
          break;
        case 'border-bottom-width':
          width = _lengthPt(e.value);
          break;
        case 'border-bottom-style':
          styleKw = e.value.trim().toLowerCase();
          break;
        case 'border-bottom-color':
          color = _cssColor(e.value);
          transparent = _isTransparent(e.value);
          break;
      }
    }

    if (styleKw == null || !_borderStyles.contains(styleKw)) return null;
    final w = width ?? 1.0; // drawable style, no explicit width => medium
    if (w <= 0 || transparent) return null;
    // A border with no explicit colour uses CSS `currentColor` (the element's
    // text colour) when one is supplied, else the document body colour.
    return (w, color ?? currentColor ?? _text);
  }

  /// Whether the *effective* bottom-border colour is explicit (so a span's
  /// `currentColor` isn't used). Walks declarations in source order because a
  /// later `border-bottom` shorthand resets the colour to its initial value
  /// (currentColor) even if an earlier longhand set one.
  bool _borderHasColor(List<MapEntry<String, String>> decls) {
    var explicit = false;
    for (final e in decls) {
      switch (e.key) {
        case 'border-bottom': // shorthand resets, then applies any colour token
          explicit = _cssColor(e.value) != null;
          break;
        case 'border-bottom-color':
          explicit = _cssColor(e.value) != null;
          break;
      }
    }
    return explicit;
  }

  /// The first length token in a border shorthand (the width), or null.
  double? _firstBorderWidth(String v) {
    final s = v.replaceAll(RegExp(r'#[0-9a-fA-F]{3,8}'), ' ').replaceAll(
        RegExp(r'(rgba?|hsla?)\([^)]*\)', caseSensitive: false), ' ');
    for (final tok in s.split(RegExp(r'\s+'))) {
      if (RegExp(r'^-?[\d.]').hasMatch(tok)) {
        final l = _lengthPt(tok);
        if (l != null) return l;
      }
    }
    return null;
  }

  /// Whether a CSS colour value is fully transparent.
  bool _isTransparent(String v) {
    final s = v.toLowerCase();
    if (RegExp(r'\btransparent\b').hasMatch(s)) return true;
    final h8 = RegExp(r'#[0-9a-f]{6}([0-9a-f]{2})\b').firstMatch(s);
    if (h8 != null && h8.group(1) == '00') return true;
    final h4 = RegExp(r'#[0-9a-f]{3}([0-9a-f])\b').firstMatch(s); // #RGBA
    if (h4 != null && h4.group(1) == '0') return true;
    if (RegExp(r'(rgba|hsla)\([^)]*,\s*0?\.?0+%?\s*\)').hasMatch(s)) {
      return true;
    }
    return false;
  }

  /// Top/bottom margin in pt, honouring source order between the `margin`
  /// shorthand and the `margin-top`/`margin-bottom` longhand (later wins).
  double _marginPt(List<MapEntry<String, String>> decls, String side) {
    double value = 0;
    for (final e in decls) {
      if (e.key == 'margin-$side') {
        value = _lengthPt(e.value) ?? value;
      } else if (e.key == 'margin') {
        final p = e.value
            .trim()
            .split(RegExp(r'\s+'))
            .map((t) => _lengthPt(t) ?? 0)
            .toList();
        if (p.isEmpty) continue;
        // 1: all; 2: v/h; 3: t/h/b; 4: t/r/b/l.
        if (side == 'top') {
          value = p[0];
        } else {
          value = p.length >= 3 ? p[2] : p[0];
        }
      }
    }
    return value;
  }

  /// Decode the common named + numeric HTML entities so exported-HTML labels
  /// render their real text (e.g. "AT&amp;T" -> "AT&T").
  String _decodeEntities(String s) {
    if (!s.contains('&')) return s;
    String charOf(int? code) => (code == null ||
            code < 0 ||
            code > 0x10FFFF ||
            (code >= 0xD800 && code <= 0xDFFF))
        ? ''
        : String.fromCharCode(code);
    return s
        .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'),
            (m) => charOf(int.tryParse(m.group(1)!, radix: 16)))
        .replaceAllMapped(
            RegExp(r'&#(\d+);'), (m) => charOf(int.tryParse(m.group(1)!)))
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&'); // amp last so "&amp;lt;" -> "&lt;"
  }

  /// The bundled fonts have no distinct ballot-box glyphs, so checked (☑/☒) and
  /// unchecked (☐) boxes render identically (both look "marked"). Map them to
  /// clear ASCII so a checklist reads correctly in the PDF.
  String _symbols(String t) {
    if (!RegExp('[☐-☒]').hasMatch(t)) return t;
    return t
        .replaceAll('☑', '[x]')
        .replaceAll('☒', '[x]')
        .replaceAll('☐', '[  ]');
  }

  static const _namedColors = <String, int>{
    'black': 0x000000,
    'white': 0xFFFFFF,
    'red': 0xFF0000,
    'green': 0x008000,
    'blue': 0x0000FF,
    'navy': 0x000080,
    'gray': 0x808080,
    'grey': 0x808080,
    'silver': 0xC0C0C0,
    'maroon': 0x800000,
    'olive': 0x808000,
    'lime': 0x00FF00,
    'teal': 0x008080,
    'aqua': 0x00FFFF,
    'cyan': 0x00FFFF,
    'purple': 0x800080,
    'fuchsia': 0xFF00FF,
    'magenta': 0xFF00FF,
    'yellow': 0xFFFF00,
    'orange': 0xFFA500,
    'darkgray': 0xA9A9A9,
    'darkgrey': 0xA9A9A9,
    'lightgray': 0xD3D3D3,
    'lightgrey': 0xD3D3D3,
    'dimgray': 0x696969,
    'dimgrey': 0x696969,
  };

  /// Parse a CSS colour (hex 3/6/8-digit, rgb()/rgba(), hsl()/hsla(), or a
  /// common named colour) found anywhere in [v]. Alpha is ignored (opaque).
  PdfColor? _cssColor(String? v) {
    if (v == null) return null;
    final s = v.trim().toLowerCase();
    PdfColor rgb(int r, int g, int b) => PdfColor.fromInt(0xFF000000 |
        (r.clamp(0, 255) << 16) |
        (g.clamp(0, 255) << 8) |
        b.clamp(0, 255));

    // #RRGGBB(AA) / #RGB(A) — longest first so "#111344" isn't read as "#111".
    final hex = RegExp(r'#([0-9a-f]{8}|[0-9a-f]{6}|[0-9a-f]{4}|[0-9a-f]{3})\b')
        .firstMatch(s);
    if (hex != null) {
      var h = hex.group(1)!;
      if (h.length == 3 || h.length == 4) {
        h = h.split('').map((c) => '$c$c').join(); // RGB(A) -> RRGGBB(AA)
      }
      if (h.length == 8) h = h.substring(0, 6); // drop alpha
      final n = int.parse(h, radix: 16);
      return PdfColor.fromInt(0xFF000000 | n);
    }
    final m = RegExp(r'rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)')
        .firstMatch(s);
    if (m != null) {
      int ch(String x) => (double.tryParse(x) ?? 0).round();
      return rgb(ch(m.group(1)!), ch(m.group(2)!), ch(m.group(3)!));
    }
    final hsl = RegExp(r'hsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%')
        .firstMatch(s);
    if (hsl != null) {
      return _hslToColor(
          double.tryParse(hsl.group(1)!) ?? 0,
          (double.tryParse(hsl.group(2)!) ?? 0) / 100,
          (double.tryParse(hsl.group(3)!) ?? 0) / 100);
    }
    for (final entry in _namedColors.entries) {
      if (RegExp('\\b${entry.key}\\b').hasMatch(s)) {
        return PdfColor.fromInt(0xFF000000 | entry.value);
      }
    }
    return null;
  }

  // CSS Color 4 reference HSL→RGB.
  PdfColor _hslToColor(double hDeg, double s, double l) {
    final h = (hDeg % 360) / 30; // hue in 0..12 units
    final a = s * (l < 0.5 ? l : 1 - l);
    double comp(double n) {
      final k = (n + h) % 12;
      final m = [k - 3.0, 9 - k, 1.0].reduce((x, y) => x < y ? x : y);
      return l - a * (m.clamp(-1.0, 1.0));
    }

    int c(double x) => (x * 255).round().clamp(0, 255);
    return PdfColor.fromInt(
        0xFF000000 | (c(comp(0)) << 16) | (c(comp(8)) << 8) | c(comp(4)));
  }

  // --- Block-level rendering --------------------------------------------------

  /// Bare elements able to carry a page-break directive with no visible
  /// content: an empty `<div …></div>`, a self-closed `<div …/>`, or `<hr …>`.
  static final _breakCandidate = RegExp(
    r'<div\b([^>]*?)>\s*</div\s*>|<div\b([^>]*?)/>|<hr\b([^>]*?)/?>',
    caseSensitive: false,
  );

  /// Style declarations of a [_breakCandidate] match (whichever alternative
  /// captured the attributes).
  Map<String, String> _breakStyleOf(Match m) =>
      _parseStyle(m.group(1) ?? m.group(2) ?? m.group(3) ?? '');

  /// Whether [style] carries a page-break directive on the requested side:
  /// `page-break-before/after: always` or the CSS-3 fragmentation spelling
  /// `break-before/after: page`. A trailing `!important` (common in exported
  /// HTML) is accepted.
  bool _breakValue(Map<String, String> style, {required bool before}) {
    final side = before ? 'before' : 'after';
    for (final k in ['page-break-$side', 'break-$side']) {
      final v = (style[k] ?? '')
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'\s*!important\s*$'), '');
      if (v == 'always' || v == 'page') return true;
    }
    return false;
  }

  /// The first standalone page-break directive in [raw], or null. Only bare
  /// elements qualify (a content-carrying div never becomes a break), and only
  /// at div-nesting depth 0 — a break div *inside* a wrapper div must not be
  /// split out of it (that would tear the wrapper's markup apart and lose its
  /// styling); it is left to the div renderer, which draws nothing for it.
  Match? _findPageBreak(String raw) {
    for (final m in _breakCandidate.allMatches(raw)) {
      if (_divDepthAt(raw, m.start) > 0) continue;
      final style = _breakStyleOf(m);
      if (_breakValue(style, before: true) ||
          _breakValue(style, before: false)) {
        return m;
      }
    }
    return null;
  }

  /// The `<div>` nesting depth at [pos]: opens minus closes among the tags
  /// before it (self-closing `<div …/>` doesn't nest).
  int _divDepthAt(String raw, int pos) {
    var depth = 0;
    for (final m in _divTag.allMatches(raw)) {
      if (m.start >= pos) break;
      if (m.group(1) == '/') {
        if (depth > 0) depth--;
      } else if (!m.group(0)!.endsWith('/>')) {
        depth++;
      }
    }
    return depth;
  }

  pw.Widget? _block(md.Node node) {
    if (node is md.Text) {
      return _divBlock(node.text) ?? _paragraph([node]);
    }
    if (node is! md.Element) return null;

    switch (node.tag) {
      case 'h1':
        return _heading(node, 23, spacingTop: 4);
      case 'h2':
        return _heading(node, 18);
      case 'h3':
        return _heading(node, 15);
      case 'h4':
        return _heading(node, 13);
      case 'h5':
        return _heading(node, 12);
      case 'h6':
        return _heading(node, 11);
      case 'p':
        final pc = node.children ?? const <md.Node>[];
        // Only treat a paragraph as raw <div> HTML when its content is pure text
        // (no inline children). Otherwise an inline-code example like
        // `<div></div>` would be flattened by textContent and mis-rendered.
        if (pc.isNotEmpty && pc.every((c) => c is md.Text)) {
          final div = _divBlock(node.textContent);
          if (div != null) return div;
        }
        return _paragraph(pc);
      case 'hr':
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 8),
          child: pw.Divider(color: PdfColors.grey400, thickness: 0.8),
        );
      case 'blockquote':
        return _blockquote(node);
      case 'pre':
        return _codeBlock(node);
      case 'ul':
      case 'ol':
        return _list(node);
      case 'table':
        return _table(node);
      case 'img':
        return _image(node);
      default:
        return _paragraph(node.children ?? const []);
    }
  }

  pw.Widget _heading(md.Element el, double size, {double spacingTop = 10}) {
    final center = profile.centerHeadings;
    // Legal documents keep one continuous spacing rhythm: the preceding
    // block's bottom gap already provides the space above a heading, and the
    // heading's own bottom gap is the same spaced-line gap as body text.
    final top = profile.legalMode ? 0.0 : spacingTop;
    final bottom = profile.legalMode ? _blockGap : 6.0;
    final text = pw.RichText(
      textAlign: center ? pw.TextAlign.center : pw.TextAlign.left,
      text: pw.TextSpan(
        children: _inline(el.children,
            color: _brandColor, sizeOverride: size, boldDefault: true),
      ),
    );
    // A RichText shrink-wraps to its text, so centring only bites when the
    // heading is stretched to the full content width first.
    final headingWidget =
        center ? pw.SizedBox(width: double.infinity, child: text) : text;
    // Brand look: a primary-colour underline rule beneath section headings
    // (h2/h3), but not the document title (h1) or minor sub-headings.
    if (profile.headingRule && size >= 15 && size <= 19) {
      return pw.Padding(
        padding: pw.EdgeInsets.only(top: top, bottom: bottom),
        child: pw.Column(
          crossAxisAlignment: center
              ? pw.CrossAxisAlignment.center
              : pw.CrossAxisAlignment.start,
          children: [
            pw.Padding(
                padding: const pw.EdgeInsets.only(bottom: 2.5),
                child: headingWidget),
            pw.Container(height: 1, color: _brandColor),
          ],
        ),
      );
    }
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: top, bottom: bottom),
      child: headingWidget,
    );
  }

  pw.Widget _paragraph(List<md.Node> children) {
    // Markdown images parse as <img> inside a paragraph; pull them out and
    // render them as block images (inline spans can't host them).
    final hasImage = children.any((n) => n is md.Element && n.tag == 'img');
    if (!hasImage) {
      return pw.Padding(
        padding: pw.EdgeInsets.only(bottom: _blockGap),
        child: _bodyRich(children, indentFirstLine: true),
      );
    }

    final widgets = <pw.Widget>[];
    final run = <md.Node>[];
    // Only the paragraph's first text run carries the first-line indent.
    var indentNext = true;
    void flushRun() {
      if (run.isEmpty) return;
      widgets.add(_bodyRich(List.of(run), indentFirstLine: indentNext));
      indentNext = false;
      run.clear();
    }

    for (final n in children) {
      if (n is md.Element && n.tag == 'img') {
        flushRun();
        widgets.add(_image(n));
        indentNext = false; // an image breaks the flow; no indent after it
      } else {
        run.add(n);
      }
    }
    flushRun();

    return pw.Padding(
      padding: pw.EdgeInsets.only(bottom: _blockGap),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: widgets,
      ),
    );
  }

  /// A body-text paragraph, honouring [PrintProfile.justifyBody] and the
  /// first-line indent. Justification only fills to the longest natural line
  /// unless the paragraph is stretched to the full content width, so a justified
  /// paragraph is wrapped in a full-width box.
  pw.Widget _bodyRich(List<md.Node> nodes, {bool indentFirstLine = false}) {
    final spans = <pw.InlineSpan>[];
    if (indentFirstLine && _firstLineIndentPt > 0) {
      // A zero-height spacer on the first line; it advances the pen like a word,
      // so wrapping and justification stay correct.
      //
      // Known limitation (accepted): under [justifyBody] the spacer is one of the
      // line's justifiable spans, so if the first line wraps after very few
      // words (e.g. a short word then a long URL/citation) an extra justification
      // gap can appear just after the indent. This is rare and cosmetic; the pdf
      // package has no native first-line indent, and this WidgetSpan spacer keeps
      // the indent at an exact width, which is the deliberate trade-off here.
      spans.add(pw.WidgetSpan(child: pw.SizedBox(width: _firstLineIndentPt)));
    }
    spans.addAll(_inline(nodes));
    final rich = pw.RichText(
      textAlign: profile.justifyBody ? pw.TextAlign.justify : pw.TextAlign.left,
      text: pw.TextSpan(children: spans),
    );
    return profile.justifyBody
        ? pw.SizedBox(width: double.infinity, child: rich)
        : rich;
  }

  /// In legal mode a quote's inner blocks each end in [_blockGap], but the
  /// quote container itself carries the gap to the next block — so the last
  /// inner block's gap would double up (a blank band inside the grey quote box
  /// plus the margin after it). Strip the trailing bottom padding, descending
  /// through zero-gap wrappers (a list wrapper is a 0-bottom Padding around a
  /// Column whose last item holds the gap). Non-legal children are untouched.
  List<pw.Widget> _trimTrailingGap(List<pw.Widget> children) {
    if (!profile.legalMode || children.isEmpty) return children;
    children[children.length - 1] = _trimTail(children.last);
    return children;
  }

  pw.Widget _trimTail(pw.Widget w) {
    if (w is pw.Padding && w.child != null) {
      final e = w.padding;
      if (e is pw.EdgeInsets) {
        if (e.bottom > 0) {
          return pw.Padding(
            padding:
                pw.EdgeInsets.only(left: e.left, top: e.top, right: e.right),
            child: w.child!,
          );
        }
        return pw.Padding(padding: e, child: _trimTail(w.child!));
      }
    }
    if (w is pw.Column && w.children.isNotEmpty) {
      final kids = List.of(w.children);
      kids[kids.length - 1] = _trimTail(kids.last);
      return pw.Column(
          crossAxisAlignment: w.crossAxisAlignment, children: kids);
    }
    return w;
  }

  pw.Widget _blockquote(md.Element el) {
    final children = _trimTrailingGap(
        (el.children ?? []).map(_block).whereType<pw.Widget>().toList());
    return pw.Container(
      margin: pw.EdgeInsets.only(bottom: _blockGap),
      padding: const pw.EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: pw.BoxDecoration(
        border: pw.Border(left: pw.BorderSide(color: _brandColor, width: 3)),
        color: PdfColors.grey100,
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  pw.Widget _codeBlock(md.Element el) {
    // <pre><code>...</code></pre>
    var code = el.textContent;
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: const PdfColor.fromInt(0xFF2B2B2B),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Text(
        code,
        style: pw.TextStyle(
          font: fonts.mono,
          fontSize: 9.5,
          color: const PdfColor.fromInt(0xFFEDEDED),
          lineSpacing: 2,
        ),
      ),
    );
  }

  pw.Widget _list(md.Element el, {int depth = 0}) {
    final ordered = el.tag == 'ol';
    // Honour an explicit start (e.g. "5. Continue" -> <ol start="5">).
    var index = ordered ? (int.tryParse(el.attributes['start'] ?? '') ?? 1) : 1;
    final items = <pw.Widget>[];
    for (final child in el.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'li') {
        items.add(_listItem(child, ordered, index, depth));
        index++;
      }
    }
    // In legal mode each item already carries the full spaced gap, so the
    // list wrapper adds none (item gap + wrapper gap would double up).
    return pw.Padding(
      padding: pw.EdgeInsets.only(bottom: profile.legalMode ? 0 : 6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: items,
      ),
    );
  }

  pw.Widget _listItem(md.Element li, bool ordered, int index, int depth) {
    final inlineNodes = <md.Node>[];
    final nested = <pw.Widget>[];
    String? checkbox;

    for (final c in li.children ?? const <md.Node>[]) {
      if (c is md.Element && (c.tag == 'ul' || c.tag == 'ol')) {
        nested.add(_list(c, depth: depth + 1));
      } else if (c is md.Element && c.tag == 'p') {
        inlineNodes.addAll(c.children ?? const []);
      } else if (c is md.Element && c.tag == 'input') {
        // GFM task lists mark checked items by the presence of the attribute,
        // whose value isn't guaranteed to be the string 'true'.
        final checked = c.attributes.containsKey('checked') &&
            c.attributes['checked'] != 'false';
        checkbox = checked ? '[x]' : '[ ]';
      } else {
        inlineNodes.add(c);
      }
    }

    final marker = checkbox ?? (ordered ? '$index.' : '•');

    final row = pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 20,
          child: pw.Text(
            marker,
            style: pw.TextStyle(
              font: checkbox != null ? fonts.mono : fonts.base,
              fontSize: 11,
              color: _text,
            ),
          ),
        ),
        pw.Expanded(
          child: pw.RichText(
            text: pw.TextSpan(children: _inline(inlineNodes)),
          ),
        ),
      ],
    );

    // Legal rhythm with a nested list: the item's own text line needs the
    // spaced gap before its children, and the nested list's last item already
    // ends in the gap — so the item adds none of its own (it would double up
    // before the next sibling). Non-legal keeps the historical flat 3pt.
    final legalNested = profile.legalMode && nested.isNotEmpty;
    return pw.Padding(
      padding: pw.EdgeInsets.only(
          left: depth * 14.0,
          bottom: legalNested ? 0 : (profile.legalMode ? _blockGap : 3)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (legalNested)
            pw.Padding(
                padding: pw.EdgeInsets.only(bottom: _blockGap), child: row)
          else
            row,
          ...nested,
        ],
      ),
    );
  }

  pw.Widget _table(md.Element table) {
    final rows = <pw.TableRow>[];
    for (final section in table.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      final isHead = section.tag == 'thead';
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        final cells = <pw.Widget>[];
        for (final cell in row.children ?? const <md.Node>[]) {
          if (cell is! md.Element) continue;
          cells.add(
            pw.Padding(
              padding:
                  const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              // Walk inline children so `<span>` fill-in lines / labels render
              // and inline code stays literal (the `code` case). Header cells
              // force white so links/code don't adopt their own colour on the
              // coloured header fill.
              child: pw.RichText(
                text: pw.TextSpan(
                  children: _inline(
                    cell.children,
                    boldDefault: isHead,
                    forceColor: isHead ? PdfColors.white : null,
                    sizeOverride: 10.5,
                  ),
                ),
              ),
            ),
          );
        }
        rows.add(
          pw.TableRow(
            decoration: isHead ? pw.BoxDecoration(color: _brandColor) : null,
            children: cells,
          ),
        );
      }
    }

    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        children: rows,
      ),
    );
  }

  pw.Widget _image(md.Element el) {
    final src = el.attributes['src'];
    final alt = el.attributes['alt'] ?? '';
    if (src != null && !src.startsWith('http')) {
      try {
        // Resolve relative image paths against the document's folder.
        final resolved = (baseDir != null && !p.isAbsolute(src))
            ? p.join(baseDir!, src)
            : src;
        final bytes = File(resolved).readAsBytesSync();
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 6),
          child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
        );
      } catch (_) {
        // fall through to placeholder
      }
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Text(
        '[image: ${alt.isEmpty ? (src ?? 'unknown') : alt}]',
        style: pw.TextStyle(
          font: fonts.italic,
          fontSize: 9,
          color: PdfColors.grey600,
        ),
      ),
    );
  }

  // --- Inline rendering -------------------------------------------------------

  List<pw.InlineSpan> _inline(
    List<md.Node>? nodes, {
    bool bold = false,
    bool italic = false,
    bool code = false,
    bool strike = false,
    bool underline = false,
    bool boldDefault = false,
    PdfColor? color,
    double? sizeOverride,
    // When set, forces this colour on *all* descendant text, links, code and
    // spans (overriding their own colours) — e.g. white table-header cells.
    PdfColor? forceColor,
  }) {
    final spans = <pw.InlineSpan>[];
    if (nodes == null) return spans;

    for (final n in nodes) {
      if (n is md.Text) {
        spans.addAll(_renderTextWithSpans(
          n.text,
          bold: bold || boldDefault,
          italic: italic,
          code: code,
          strike: strike,
          underline: underline,
          color: color,
          size: sizeOverride,
          forceColor: forceColor,
        ));
      } else if (n is md.Element) {
        switch (n.tag) {
          case 'strong':
            spans.addAll(_inline(n.children,
                bold: true,
                italic: italic,
                code: code,
                strike: strike,
                underline: underline,
                // Brand look: bold emphasis takes the primary colour — but not
                // in legal mode, which stays monochrome.
                color: color ??
                    (profile.headingRule && !profile.legalMode
                        ? _primary
                        : null),
                sizeOverride: sizeOverride,
                boldDefault: boldDefault,
                forceColor: forceColor));
            break;
          case 'em':
            spans.addAll(_inline(n.children,
                bold: bold,
                italic: true,
                code: code,
                strike: strike,
                underline: underline,
                color: color,
                sizeOverride: sizeOverride,
                boldDefault: boldDefault,
                forceColor: forceColor));
            break;
          case 'del':
            spans.addAll(_inline(n.children,
                bold: bold,
                italic: italic,
                code: code,
                strike: true,
                underline: underline,
                color: color,
                sizeOverride: sizeOverride,
                boldDefault: boldDefault,
                forceColor: forceColor));
            break;
          case 'u':
          case 'ins':
            spans.addAll(_inline(n.children,
                bold: bold,
                italic: italic,
                code: code,
                strike: strike,
                underline: true,
                color: color,
                sizeOverride: sizeOverride,
                boldDefault: boldDefault,
                forceColor: forceColor));
            break;
          case 'code':
            spans.add(
              pw.TextSpan(
                text: n.textContent,
                style: _textStyle(
                  code: true,
                  // Honour a surrounding underline (e.g. a code link label or
                  // `<u>`) so links keep their affordance.
                  underline: underline,
                  // A forced colour (white table headers) wins; otherwise the
                  // branded inline-code colour.
                  color: forceColor ?? const PdfColor.fromInt(0xFFB5179E),
                  size: sizeOverride,
                ),
              ),
            );
            break;
          case 'a':
            // Walk the link's children so a `<span>` label renders and an inline
            // code label stays literal. The link colour is a *fallback* (a
            // span's own colour / `transparent` still wins, so redacted link
            // text stays hidden); only a truly forced context (a header) forces
            // the colour via forceColor.
            spans.addAll(_inline(
              n.children,
              bold: bold,
              italic: italic,
              underline: profile.legalMode || !profile.headingRule,
              sizeOverride: sizeOverride,
              boldDefault: boldDefault,
              color: profile.legalMode ? _text : _accent,
              forceColor: forceColor,
            ));
            break;
          case 'br':
            spans.add(const pw.TextSpan(text: '\n'));
            break;
          default:
            spans.addAll(_inline(n.children,
                bold: bold,
                italic: italic,
                code: code,
                strike: strike,
                underline: underline,
                color: color,
                sizeOverride: sizeOverride,
                boldDefault: boldDefault,
                forceColor: forceColor));
        }
      }
    }
    return spans;
  }

  static final _spanOpen = RegExp(r'<span\b([^>]*)>', caseSensitive: false);
  static final _spanAnyTag = RegExp(r'<(/?)span\b[^>]*>', caseSensitive: false);

  /// Test hook for the inline-`<span>` rendering (blank lines / styled labels).
  @visibleForTesting
  List<pw.InlineSpan> renderInlineText(
    String text, {
    bool underline = false,
    bool strike = false,
    PdfColor? color,
    PdfColor? forceColor,
  }) =>
      _renderTextWithSpans(text,
          underline: underline,
          strike: strike,
          color: color,
          forceColor: forceColor);

  /// Split raw inline text into styled runs, rendering inline `<span>` HTML that
  /// package:markdown otherwise leaves as literal text. Legal/manuscript docs
  /// use spans for fill-in "blank" lines (a span with a visible bottom border)
  /// and small styled labels. Text without a span returns as a single run, and
  /// inline code is never touched. Spans are matched with a balanced scan so a
  /// nested `<span>` doesn't leak its outer `</span>`.
  ///
  /// Known limitation (accepted): when a span wraps Markdown inline syntax, e.g.
  /// `<span style="color:red">**bold**</span>`, the Markdown parser splits the
  /// span's open/close tags into separate sibling nodes from the parsed
  /// `strong`/`a`/… element, so each text node is handled in isolation here. The
  /// tags are stripped (no leak) and the emphasis still renders, but the span's
  /// own colour/weight is not applied to that inner element — the same behaviour
  /// as the existing inline `<u>` handling.
  List<pw.InlineSpan> _renderTextWithSpans(
    String text, {
    bool bold = false,
    bool italic = false,
    bool code = false,
    bool strike = false,
    bool underline = false,
    PdfColor? color,
    double? size,
    bool transparentColor = false,
    PdfColor? forceColor,
  }) {
    // Decode HTML entities in prose/span-adjacent text (but never in code, where
    // `&amp;` is literal), matching the entity handling in _spanFragment. A
    // literal `<br>` the author wrote is a line break — package:markdown leaves
    // it as text, so without this it would print as the characters "<br>"
    // (notably inside headings, e.g. a two-line court header). Text under an
    // inherited transparent currentColor is hidden (redaction) — unless a
    // forced colour overrides it (e.g. white table headers).
    pw.InlineSpan run(String s) => (transparentColor && forceColor == null)
        ? const pw.TextSpan(text: '')
        : pw.TextSpan(
            text: _symbols(code
                ? s
                : _decodeEntities(s.replaceAll(
                    RegExp(r'<br\s*/?>', caseSensitive: false), '\n'))),
            style: _textStyle(
              bold: bold,
              italic: italic,
              code: code,
              strike: strike,
              underline: underline,
              color: forceColor ?? color,
              size: size,
            ),
          );
    // Enter the parser for *any* span tag (open or close). Gating on a complete
    // pair would let a single unclosed/stray tag fall through and leak; the loop
    // strips those instead. HTML tag names are case-insensitive (as is the regex).
    if (code || !_spanAnyTag.hasMatch(text)) return [run(text)];

    final out = <pw.InlineSpan>[];
    var i = 0;
    while (i < text.length) {
      final openIt = _spanOpen.allMatches(text, i).iterator;
      if (!openIt.moveNext()) {
        // No further opening tag — emit the remainder, stripping any stray
        // closing tags so nothing leaks.
        out.add(run(_stripSpanTags(text.substring(i))));
        break;
      }
      final open = openIt.current;
      if (open.start > i) {
        // Strip any stray closing tag that precedes the next opener.
        out.add(run(_stripSpanTags(text.substring(i, open.start))));
      }
      if (open.group(0)!.endsWith('/>')) {
        // Self-closing span. A bordered one is an empty fill-in line; an
        // unstyled one is structural (e.g. a bookmark) and contributes nothing.
        // Either way it has no content, so don't run the balanced scan (which
        // would otherwise swallow a following, valid fill-in span).
        final selfAttrs = open.group(1) ?? '';
        if (_spanIsBlank(selfAttrs, '')) {
          out.add(_spanFragment(selfAttrs, '',
              bold: bold,
              italic: italic,
              underline: underline,
              strike: strike,
              color: color,
              size: size,
              transparentColor: transparentColor,
              forceColor: forceColor));
        }
        i = open.end;
        continue;
      }
      final matched = _matchSpan(text, open.start);
      if (matched == null) {
        // Unbalanced opening tag — drop just this tag and keep parsing the rest,
        // so a following *balanced* fill-in span is still rendered rather than
        // the whole remainder being stripped to text.
        i = open.end;
        continue;
      }
      final (contentStart, closeStart, closeEnd) = matched;
      final attrs = open.group(1) ?? '';
      final content = text.substring(contentStart, closeStart);
      if (_spanIsBlank(attrs, content)) {
        // The outer span itself is the fill-in line (even if its whitespace is
        // wrapped in a nested span) — draw it rather than recursing into the
        // empty child.
        out.add(_spanFragment(attrs, content,
            bold: bold,
            italic: italic,
            underline: underline,
            strike: strike,
            color: color,
            size: size,
            transparentColor: transparentColor,
            forceColor: forceColor));
      } else if (_spanOpen.hasMatch(content)) {
        // Nested span(s): recurse so an inner blank/label still renders instead
        // of being flattened to text, inheriting the outer span's styling
        // (including a transparent currentColor, so an inner colourless border
        // stays invisible).
        final os = _parseStyle(attrs);
        final ofw = (os['font-weight'] ?? '').toLowerCase();
        final odeco = (os['text-decoration'] ?? '').toLowerCase();
        final oColor = os['color'];
        out.addAll(_renderTextWithSpans(
          content,
          bold: bold || ofw == 'bold' || (int.tryParse(ofw) ?? 0) >= 600,
          italic: italic || (os['font-style'] ?? '').toLowerCase() == 'italic',
          underline: underline || odeco.contains('underline'),
          strike: strike || odeco.contains('line-through'),
          color: _cssColor(oColor ?? '') ?? color,
          size: _lengthPt(os['font-size']) ?? size,
          transparentColor: (oColor != null && _isTransparent(oColor)) ||
              (oColor == null && transparentColor),
          forceColor: forceColor,
        ));
      } else {
        out.add(_spanFragment(
          attrs,
          content,
          bold: bold,
          italic: italic,
          underline: underline,
          strike: strike,
          color: color,
          size: size,
          transparentColor: transparentColor,
          forceColor: forceColor,
        ));
      }
      i = closeEnd;
    }
    return out;
  }

  static final _spanStrip = RegExp(r'</?span[^>]*>', caseSensitive: false);
  String _stripSpanTags(String s) => s.replaceAll(_spanStrip, '');

  /// (contentStart, closeStart, closeEnd) of the `</span>` balancing the `<span>`
  /// opening at [openAbs], accounting for nested spans; null if unbalanced.
  (int, int, int)? _matchSpan(String s, int openAbs) {
    var depth = 0;
    var contentStart = -1;
    for (final m in _spanAnyTag.allMatches(s, openAbs)) {
      if (m.group(1) == '/') {
        depth--;
        if (depth == 0) return (contentStart, m.start, m.end);
      } else if (m.group(0)!.endsWith('/>')) {
        continue; // self-closing span — not a nesting open
      } else {
        depth++;
        if (depth == 1) contentStart = m.end; // just past the outer opening tag
      }
    }
    return null;
  }

  /// A span's raw content with all tags and entities removed and trimmed — used
  /// to decide whether a bordered span is an empty fill-in blank.
  String _effectiveText(String raw) => _decodeEntities(raw
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll(
              RegExp(r'&nbsp;|&#160;|&#xA0;', caseSensitive: false), ' '))
      .trim();

  /// Whether a span is a fill-in blank: a visible bottom border and no real text
  /// (its whitespace may itself be wrapped in nested spans).
  bool _spanIsBlank(String attrs, String content) =>
      _resolveBorder(_styleDecls(attrs)) != null &&
      _effectiveText(content).isEmpty;

  /// Render one `<span style="…">…</span>`: a visible bottom border with no real
  /// text becomes a baseline rule of the requested width (a signature/date
  /// blank); anything else becomes a styled text run (colour/weight/size),
  /// inheriting the surrounding underline/strike decoration.
  pw.InlineSpan _spanFragment(
    String attrs,
    String innerRaw, {
    bool bold = false,
    bool italic = false,
    bool underline = false,
    bool strike = false,
    PdfColor? color,
    double? size,
    bool transparentColor = false,
    PdfColor? forceColor,
  }) {
    final style = _parseStyle(attrs);
    final decls = _styleDecls(attrs);
    // A forced colour (white table headers) overrides the span's own; otherwise
    // its own colour is `currentColor` for a colourless border and the label
    // text colour.
    final spanColor = forceColor ?? _cssColor(style['color']) ?? color;
    final border = _resolveBorder(decls, currentColor: spanColor);
    // A literal <br> inside a styled label is a line break (matching plain
    // prose and headings); blank detection (_effectiveText) still treats it
    // as whitespace so a fill-in blank containing one stays a blank.
    final inner = _decodeEntities(innerRaw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(
            RegExp(r'&nbsp;|&#160;|&#xA0;', caseSensitive: false), ' '));
    final hasText = inner.trim().isNotEmpty;

    if (border != null && !hasText) {
      // A colourless border uses currentColor; if that colour is transparent
      // (its own `color: transparent`/zero-alpha, or an inherited transparent
      // from a wrapper span) the blank is intentionally invisible.
      final own = style['color'];
      final transparentCurrent = (own != null && _isTransparent(own)) ||
          (own == null && transparentColor);
      // A forced colour makes the border visible regardless of transparency.
      if (forceColor == null && transparentCurrent && !_borderHasColor(decls)) {
        return const pw.TextSpan(text: '');
      }
      // CSS width is subject to the min-width floor, so honour the larger of the
      // two positive values. A collapse happens only when the *width* itself is
      // explicitly zero (length or %); a bare `min-width:0` is a reset, not a
      // collapse, and an unresolved non-zero % falls back to the default.
      final wPt = _lengthPt(style['width']);
      final mwPt = _lengthPt(style['min-width']);
      final positive = [wPt, mwPt].whereType<double>().where((v) => v > 0);
      final double width;
      if (positive.isNotEmpty) {
        width = positive.reduce((a, b) => a > b ? a : b);
      } else if (wPt == 0 || _percent(style['width']) == 0) {
        return const pw.TextSpan(text: ''); // width explicitly zero → collapsed
      } else {
        width =
            108.0; // missing / min-width:0 / unresolved non-zero % → default
      }
      final thickness = border.$1 < 0.6 ? 0.6 : border.$1;
      final lineSize = size ?? 11.0;
      // A zero-baseline WidgetSpan sits on the text baseline, so the container's
      // bottom border renders as an underline blank at the baseline.
      return pw.WidgetSpan(
        child: pw.Container(
          width: width,
          height: lineSize,
          margin: const pw.EdgeInsets.symmetric(horizontal: 2),
          decoration: pw.BoxDecoration(
            border: pw.Border(
                bottom: pw.BorderSide(
                    color: forceColor ?? border.$2, width: thickness)),
          ),
        ),
      );
    }

    final fw = (style['font-weight'] ?? '').toLowerCase();
    final isBold = bold || fw == 'bold' || (int.tryParse(fw) ?? 0) >= 600;
    final isItalic =
        italic || (style['font-style'] ?? '').toLowerCase() == 'italic';
    if (!hasText) {
      // A truly empty structural span (anchor/bookmark) contributes nothing; a
      // whitespace-only span is a separator and must keep a space so adjacent
      // words don't merge.
      return pw.TextSpan(text: inner.isEmpty ? '' : ' ');
    }

    // Transparent text (its own `color: transparent`/zero-alpha, or an inherited
    // transparent currentColor) is intentionally hidden — e.g. redacted
    // placeholder text — unless a forced colour overrides it.
    final own = style['color'];
    if (forceColor == null &&
        ((own != null && _isTransparent(own)) ||
            (own == null && transparentColor))) {
      return const pw.TextSpan(text: '');
    }

    final deco = (style['text-decoration'] ?? '').toLowerCase();
    return pw.TextSpan(
      text: _symbols(inner),
      style: _textStyle(
        bold: isBold,
        italic: isItalic,
        // Combine the surrounding decoration with the span's own.
        underline: underline || deco.contains('underline'),
        strike: strike || deco.contains('line-through'),
        color: spanColor,
        size: _lengthPt(style['font-size']) ?? size,
      ),
    );
  }

  pw.TextStyle _textStyle({
    bool bold = false,
    bool italic = false,
    bool code = false,
    bool strike = false,
    bool underline = false,
    PdfColor? color,
    double? size,
  }) {
    final pw.Font font;
    if (code) {
      font = fonts.mono;
    } else if (bold && italic) {
      font = fonts.boldItalic;
    } else if (bold) {
      font = fonts.bold;
    } else if (italic) {
      font = fonts.italic;
    } else {
      font = fonts.base;
    }

    final decorations = <pw.TextDecoration>[
      if (strike) pw.TextDecoration.lineThrough,
      if (underline) pw.TextDecoration.underline,
    ];

    return pw.TextStyle(
      font: font,
      fontSize: size ?? 11,
      color: color ?? _text,
      lineSpacing: _leadingFor(size ?? 11),
      decoration:
          decorations.isEmpty ? null : pw.TextDecoration.combine(decorations),
    );
  }
}
