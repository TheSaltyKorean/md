import 'dart:convert';
import 'dart:io';

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

  List<pw.Widget> build(String markdown) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
      // The toolbar / AppFlowy round-trip emit <u>…</u>; package:markdown leaves
      // inline HTML as text, so parse it into a 'u' element ourselves.
      inlineSyntaxes: [_UnderlineSyntax()],
    );
    final nodes = document.parseLines(const LineSplitter().convert(markdown));
    return nodes.map(_block).whereType<pw.Widget>().toList();
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
  List<pw.Widget> _renderDivSequence(String raw) {
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
      final w =
          _htmlDiv(open.group(1) ?? '', raw.substring(contentStart, closeStart));
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
  /// holds more divs) recurses; an empty div with a *visible* `border-bottom`
  /// becomes a signature/blank line; a div with text becomes a styled label.
  /// Returns null for an empty, borderless/structural div.
  pw.Widget? _htmlDiv(String attrs, String content) {
    final decls = _styleDecls(attrs);
    if (_divOpen.hasMatch(content)) {
      final inner = _renderDivSequence(content);
      if (inner.isEmpty) return null;
      final col = pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start, children: inner);
      // Apply the wrapper div's own vertical spacing around the inner content.
      final mt = _marginPt(decls, 'top');
      final mb = _marginPt(decls, 'bottom');
      return (mt > 0 || mb > 0)
          ? pw.Padding(
              padding: pw.EdgeInsets.only(top: mt, bottom: mb), child: col)
          : col;
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
      if (widthPt != null) {
        sized = widthPt <= 0
            ? pw.SizedBox()
            : pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.SizedBox(width: widthPt, child: line));
      } else if (widthPct != null && widthPct <= 0) {
        sized = pw.SizedBox(); // explicit 0% => collapsed rule
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
        padding: pw.EdgeInsets.only(top: gapTop + height, bottom: gapBottom + 2),
        child: sized,
      );
    }

    final size = _lengthPt(style['font-size']) ?? 10;
    final color = _cssColor(style['color']) ?? _text;
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: gapTop, bottom: gapBottom + 4),
      child: pw.Text(text,
          style: pw.TextStyle(fontSize: size, color: color, font: fonts.base)),
    );
  }

  /// Declarations from a style attribute, in source order (so shorthand vs
  /// longhand precedence can follow CSS "later wins" rules).
  List<MapEntry<String, String>> _styleDecls(String attrs) {
    final m = RegExp(r'''style\s*=\s*("([^"]*)"|'([^']*)')''',
            caseSensitive: false)
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
    'solid', 'dashed', 'dotted', 'double', 'groove', 'ridge', 'inset', 'outset'
  };

  /// The effective bottom border as (widthPt, colour), or null when invisible.
  /// Merges the `border-bottom` shorthand with longhand `border-bottom-*`
  /// overrides (later declaration wins) and follows CSS visibility rules: a
  /// border needs a drawable *style* keyword (a width or colour alone leaves the
  /// style at `none`), a positive width, and a non-transparent colour.
  (double, PdfColor)? _resolveBorder(List<MapEntry<String, String>> decls) {
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
    return (w, color ?? _text);
  }

  /// The first length token in a border shorthand (the width), or null.
  double? _firstBorderWidth(String v) {
    final s = v
        .replaceAll(RegExp(r'#[0-9a-fA-F]{3,8}'), ' ')
        .replaceAll(RegExp(r'(rgba?|hsla?)\([^)]*\)', caseSensitive: false), ' ');
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
    if (RegExp(r'(rgba|hsla)\([^)]*,\s*0?\.?0+%?\s*\)').hasMatch(s)) return true;
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
    String charOf(int? code) =>
        (code == null || code < 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF))
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
    'black': 0x000000, 'white': 0xFFFFFF, 'red': 0xFF0000, 'green': 0x008000,
    'blue': 0x0000FF, 'navy': 0x000080, 'gray': 0x808080, 'grey': 0x808080,
    'silver': 0xC0C0C0, 'maroon': 0x800000, 'olive': 0x808000,
    'lime': 0x00FF00, 'teal': 0x008080, 'aqua': 0x00FFFF, 'cyan': 0x00FFFF,
    'purple': 0x800080, 'fuchsia': 0xFF00FF, 'magenta': 0xFF00FF,
    'yellow': 0xFFFF00, 'orange': 0xFFA500, 'darkgray': 0xA9A9A9,
    'darkgrey': 0xA9A9A9, 'lightgray': 0xD3D3D3, 'lightgrey': 0xD3D3D3,
    'dimgray': 0x696969, 'dimgrey': 0x696969,
  };

  /// Parse a CSS colour (hex 3/6/8-digit, rgb()/rgba(), hsl()/hsla(), or a
  /// common named colour) found anywhere in [v]. Alpha is ignored (opaque).
  PdfColor? _cssColor(String? v) {
    if (v == null) return null;
    final s = v.trim().toLowerCase();
    PdfColor rgb(int r, int g, int b) => PdfColor.fromInt(
        0xFF000000 | (r.clamp(0, 255) << 16) | (g.clamp(0, 255) << 8) | b.clamp(0, 255));

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
    final hsl =
        RegExp(r'hsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%')
            .firstMatch(s);
    if (hsl != null) {
      return _hslToColor(double.tryParse(hsl.group(1)!) ?? 0,
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
        padding: pw.EdgeInsets.only(top: spacingTop, bottom: 6),
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
      padding: pw.EdgeInsets.only(top: spacingTop, bottom: 6),
      child: headingWidget,
    );
  }

  pw.Widget _paragraph(List<md.Node> children) {
    // Markdown images parse as <img> inside a paragraph; pull them out and
    // render them as block images (inline spans can't host them).
    final hasImage = children.any((n) => n is md.Element && n.tag == 'img');
    if (!hasImage) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
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
      padding: const pw.EdgeInsets.only(bottom: 8),
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
      textAlign:
          profile.justifyBody ? pw.TextAlign.justify : pw.TextAlign.left,
      text: pw.TextSpan(children: spans),
    );
    return profile.justifyBody
        ? pw.SizedBox(width: double.infinity, child: rich)
        : rich;
  }

  pw.Widget _blockquote(md.Element el) {
    final children =
        (el.children ?? []).map(_block).whereType<pw.Widget>().toList();
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
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
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
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

    return pw.Padding(
      padding: pw.EdgeInsets.only(left: depth * 14.0, bottom: 3),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
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
          ),
          ...nested,
        ],
      ),
    );
  }

  pw.Widget _table(md.Element table) {
    final rows = <pw.TableRow>[];
    final headerStyle = pw.TextStyle(
      font: fonts.bold,
      fontSize: 10.5,
      color: PdfColors.white,
    );
    final cellStyle =
        pw.TextStyle(font: fonts.base, fontSize: 10.5, color: _text);

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
              child: pw.Text(cell.textContent,
                  style: isHead ? headerStyle : cellStyle),
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
  }) {
    final spans = <pw.InlineSpan>[];
    if (nodes == null) return spans;

    for (final n in nodes) {
      if (n is md.Text) {
        spans.add(
          pw.TextSpan(
            text: _symbols(n.text),
            style: _textStyle(
              bold: bold || boldDefault,
              italic: italic,
              code: code,
              strike: strike,
              underline: underline,
              color: color,
              size: sizeOverride,
            ),
          ),
        );
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
                boldDefault: boldDefault));
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
                boldDefault: boldDefault));
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
                boldDefault: boldDefault));
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
                boldDefault: boldDefault));
            break;
          case 'code':
            spans.add(
              pw.TextSpan(
                text: n.textContent,
                style: _textStyle(
                  code: true,
                  color: const PdfColor.fromInt(0xFFB5179E),
                  size: sizeOverride,
                ),
              ),
            );
            break;
          case 'a':
            spans.add(
              pw.TextSpan(
                text: n.textContent,
                style: _textStyle(
                  bold: bold || boldDefault,
                  italic: italic,
                  // Legal mode prints links in the body colour (monochrome).
                  color: profile.legalMode ? _text : _accent,
                  size: sizeOverride,
                  // Brand links are coloured but not underlined; legal/plain
                  // links keep the underline.
                  underline: profile.legalMode || !profile.headingRule,
                ),
              ),
            );
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
                boldDefault: boldDefault));
        }
      }
    }
    return spans;
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
