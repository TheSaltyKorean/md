import 'dart:convert';
import 'dart:io';

import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/print_profile.dart';

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

  List<pw.Widget> build(String markdown) {
    final document = md.Document(
      extensionSet: md.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
    );
    final nodes = document.parseLines(const LineSplitter().convert(markdown));
    return nodes.map(_block).whereType<pw.Widget>().toList();
  }

  // --- Block-level rendering --------------------------------------------------

  pw.Widget? _block(md.Node node) {
    if (node is md.Text) {
      return _paragraph([node]);
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
        return _paragraph(node.children ?? const []);
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
    return pw.Padding(
      padding: pw.EdgeInsets.only(top: spacingTop, bottom: 6),
      child: pw.RichText(
        text: pw.TextSpan(
          children: _inline(el.children,
              color: _primary, sizeOverride: size, boldDefault: true),
        ),
      ),
    );
  }

  pw.Widget _paragraph(List<md.Node> children) {
    // Markdown images parse as <img> inside a paragraph; pull them out and
    // render them as block images (inline spans can't host them).
    final hasImage = children.any((n) => n is md.Element && n.tag == 'img');
    if (!hasImage) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.RichText(text: pw.TextSpan(children: _inline(children))),
      );
    }

    final widgets = <pw.Widget>[];
    final run = <md.Node>[];
    void flushRun() {
      if (run.isEmpty) return;
      widgets
          .add(pw.RichText(text: pw.TextSpan(children: _inline(List.of(run)))));
      run.clear();
    }

    for (final n in children) {
      if (n is md.Element && n.tag == 'img') {
        flushRun();
        widgets.add(_image(n));
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

  pw.Widget _blockquote(md.Element el) {
    final children =
        (el.children ?? []).map(_block).whereType<pw.Widget>().toList();
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.fromLTRB(12, 4, 8, 4),
      decoration: pw.BoxDecoration(
        border: pw.Border(left: pw.BorderSide(color: _primary, width: 3)),
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
    var index = 1;
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
        checkbox = c.attributes['checked'] == 'true' ? '[x]' : '[ ]';
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
            decoration: isHead ? pw.BoxDecoration(color: _primary) : null,
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
            text: n.text,
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
                color: color,
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
                  color: _primary,
                  size: sizeOverride,
                  underline: true,
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
      lineSpacing: 2.5,
      decoration:
          decorations.isEmpty ? null : pw.TextDecoration.combine(decorations),
    );
  }
}
