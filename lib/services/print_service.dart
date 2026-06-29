import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/print_profile.dart';
import 'markdown_pdf_builder.dart';

/// Builds branded PDFs from Markdown and drives the platform print / share /
/// PDF-export flows. Headers, footers, page numbers, logos and watermarks all
/// come from the supplied [PrintProfile].
class PrintService {
  /// Open the OS print dialog with a rendered, branded document.
  Future<void> printDocument({
    required String markdown,
    required PrintProfile profile,
    required String title,
  }) async {
    await Printing.layoutPdf(
      name: title,
      onLayout: (format) => _buildPdf(
          markdown: markdown, profile: profile, title: title, format: format),
    );
  }

  /// Share / export the document as a PDF file.
  Future<void> sharePdf({
    required String markdown,
    required PrintProfile profile,
    required String title,
  }) async {
    final bytes = await _buildPdf(
      markdown: markdown,
      profile: profile,
      title: title,
      format: PdfPageFormat.a4,
    );
    final safe = title.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    await Printing.sharePdf(bytes: bytes, filename: '$safe.pdf');
  }

  /// Render to bytes for a specific page format (used by the in-app
  /// [PdfPreview] which supplies the format).
  Future<Uint8List> generate({
    required String markdown,
    required PrintProfile profile,
    required String title,
    required PdfPageFormat format,
    String? baseDir,
  }) =>
      _buildPdf(
        markdown: markdown,
        profile: profile,
        title: title,
        format: format,
        baseDir: baseDir,
      );

  // --- PDF assembly -----------------------------------------------------------

  Future<Uint8List> _buildPdf({
    required String markdown,
    required PrintProfile profile,
    required String title,
    required PdfPageFormat format,
    String? baseDir,
  }) async {
    final fonts = await _resolveFonts(profile.fontFamily);
    final logo = await _loadLogo(profile.logoPath);
    final builder =
        MarkdownPdfBuilder(profile: profile, fonts: fonts, baseDir: baseDir);
    final content = builder.build(markdown);

    // Brand "cover" mode: the logo appears once at the top of the document
    // (not as a running header), like the SK Meridian brief.
    final useCover = profile.coverLogo && logo != null;
    final body = <pw.Widget>[
      if (useCover) _coverLogo(logo),
      ...content,
    ];

    final margin = profile.marginCm * PdfPageFormat.cm;
    final doc = pw.Document(title: title);

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: format.copyWith(
            marginLeft: margin,
            marginRight: margin,
            marginTop: margin,
            marginBottom: margin,
          ),
          theme: pw.ThemeData.withFont(
            base: fonts.base,
            bold: fonts.bold,
            italic: fonts.italic,
            boldItalic: fonts.boldItalic,
          ),
          buildBackground: profile.watermarkText == null
              ? null
              : (context) => _watermark(profile.watermarkText!),
        ),
        // In cover mode the logo is rendered once at the top of the body, so we
        // omit it from the running header — but keep the header itself so any
        // title, company name, classification label and accent rule still appear
        // on every page.
        header: (context) =>
            _header(context, profile, title, useCover ? null : logo),
        footer: (context) => _footer(context, profile, title),
        build: (context) => body,
      ),
    );

    return doc.save();
  }

  pw.Widget _coverLogo(pw.MemoryImage logo) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Container(
        height: 30,
        alignment: pw.Alignment.centerLeft,
        child: pw.Image(logo, fit: pw.BoxFit.contain),
      ),
    );
  }

  pw.Widget _watermark(String text) {
    return pw.Watermark.text(
      text,
      style: pw.TextStyle(
        color: PdfColors.grey300,
        fontSize: 96,
        fontWeight: pw.FontWeight.bold,
      ),
      angle: 0.6,
    );
  }

  pw.Widget _header(
    pw.Context context,
    PrintProfile profile,
    String title,
    pw.MemoryImage? logo,
  ) {
    final primary = PdfColor.fromInt(profile.primaryColor);

    final brandRow = <pw.Widget>[];
    if (logo != null) {
      brandRow.add(pw.Container(height: 26, child: pw.Image(logo)));
    }
    if (profile.companyName != null && profile.companyName!.isNotEmpty) {
      if (brandRow.isNotEmpty) brandRow.add(pw.SizedBox(width: 8));
      brandRow.add(
        pw.Text(
          profile.companyName!,
          style: pw.TextStyle(
            fontWeight: pw.FontWeight.bold,
            fontSize: 12,
            color: primary,
          ),
        ),
      );
    }

    final headerTitle =
        profile.headerText ?? (profile.showTitleInHeader ? title : null);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Row(children: brandRow),
            if (profile.confidentialLabel != null &&
                profile.confidentialLabel!.isNotEmpty)
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: pw.BoxDecoration(
                  color: primary,
                  borderRadius: pw.BorderRadius.circular(4),
                ),
                child: pw.Text(
                  profile.confidentialLabel!,
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
        if (headerTitle != null && headerTitle.isNotEmpty)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 4),
            child: pw.Text(
              headerTitle,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ),
        if (profile.accentRule)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: pw.Container(height: 1.5, color: primary),
          )
        else
          pw.SizedBox(height: 6),
      ],
    );
  }

  pw.Widget _footer(pw.Context context, PrintProfile profile, String title) {
    final primary = PdfColor.fromInt(profile.primaryColor);

    // Brand footer: a single centred grey line with a hairline rule above,
    // matching "SK Meridian LLC — <Title> | Page N of M".
    if (profile.footerCentered) {
      final bits = <String>[];
      if (profile.footerText != null && profile.footerText!.isNotEmpty) {
        bits.add(profile.footerText!);
      }
      if (title.isNotEmpty) bits.add(title);
      var line = bits.join('  —  ');
      if (profile.showPageNumbers) {
        line = line.isEmpty
            ? 'Page ${context.pageNumber} of ${context.pagesCount}'
            : '$line  |  Page ${context.pageNumber} of ${context.pagesCount}';
      }
      return pw.Container(
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            top: pw.BorderSide(color: PdfColor.fromInt(0xFFD8DAE6), width: 0.5),
          ),
        ),
        padding: const pw.EdgeInsets.only(top: 5),
        alignment: pw.Alignment.center,
        child: pw.Text(
          line,
          style: const pw.TextStyle(
              fontSize: 7.5, color: PdfColor.fromInt(0xFF8A8DA0)),
        ),
      );
    }

    final parts = <String>[];
    if (profile.footerText != null && profile.footerText!.isNotEmpty) {
      parts.add(profile.footerText!);
    }
    if (profile.confidentialLabel != null &&
        profile.confidentialLabel!.isNotEmpty) {
      parts.add(profile.confidentialLabel!);
    }
    final left = parts.join('  •  ');

    final right = <String>[];
    if (profile.showDate) right.add(_today());
    if (profile.showPageNumbers) {
      right.add('Page ${context.pageNumber} of ${context.pagesCount}');
    }

    return pw.Column(
      children: [
        if (profile.accentRule)
          pw.Container(
            height: 0.8,
            color: PdfColors.grey300,
            margin: const pw.EdgeInsets.only(bottom: 4),
          ),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              left,
              style: pw.TextStyle(fontSize: 8, color: primary),
            ),
            pw.Text(
              right.join('   '),
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
            ),
          ],
        ),
      ],
    );
  }

  String _today() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }

  Future<pw.MemoryImage?> _loadLogo(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      final bytes = await File(path).readAsBytes();
      return pw.MemoryImage(bytes);
    } catch (e) {
      debugPrint('logo load failed: $e');
      return null;
    }
  }

  /// Resolve a font family to a [PdfFontSet]. Falls back to the always-available
  /// built-in PDF standard fonts when a Google Font cannot be fetched (e.g.
  /// offline), so printing never fails for lack of a typeface.
  Future<PdfFontSet> _resolveFonts(String family) async {
    Future<pw.Font> safe(
        Future<pw.Font> Function() loader, pw.Font fallback) async {
      try {
        return await loader();
      } catch (_) {
        return fallback;
      }
    }

    final mono =
        await safe(PdfGoogleFonts.robotoMonoRegular, pw.Font.courier());

    switch (family) {
      case 'Inter':
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.interRegular, pw.Font.helvetica()),
          bold: await safe(PdfGoogleFonts.interBold, pw.Font.helveticaBold()),
          italic: await safe(
              PdfGoogleFonts.interItalic, pw.Font.helveticaOblique()),
          boldItalic: await safe(
              PdfGoogleFonts.interBoldItalic, pw.Font.helveticaBoldOblique()),
          mono: mono,
        );
      case 'Lato':
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.latoRegular, pw.Font.helvetica()),
          bold: await safe(PdfGoogleFonts.latoBold, pw.Font.helveticaBold()),
          italic:
              await safe(PdfGoogleFonts.latoItalic, pw.Font.helveticaOblique()),
          boldItalic: await safe(
              PdfGoogleFonts.latoBoldItalic, pw.Font.helveticaBoldOblique()),
          mono: mono,
        );
      case 'Merriweather':
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.merriweatherRegular, pw.Font.times()),
          bold:
              await safe(PdfGoogleFonts.merriweatherBold, pw.Font.timesBold()),
          italic: await safe(
              PdfGoogleFonts.merriweatherItalic, pw.Font.timesItalic()),
          boldItalic: await safe(
              PdfGoogleFonts.merriweatherBoldItalic, pw.Font.timesBoldItalic()),
          mono: mono,
        );
      case 'Montserrat':
        return PdfFontSet(
          base:
              await safe(PdfGoogleFonts.montserratRegular, pw.Font.helvetica()),
          bold: await safe(
              PdfGoogleFonts.montserratBold, pw.Font.helveticaBold()),
          italic: await safe(
              PdfGoogleFonts.montserratItalic, pw.Font.helveticaOblique()),
          boldItalic: await safe(PdfGoogleFonts.montserratBoldItalic,
              pw.Font.helveticaBoldOblique()),
          mono: mono,
        );
      case 'Open Sans':
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.openSansRegular, pw.Font.helvetica()),
          bold:
              await safe(PdfGoogleFonts.openSansBold, pw.Font.helveticaBold()),
          italic: await safe(
              PdfGoogleFonts.openSansItalic, pw.Font.helveticaOblique()),
          boldItalic: await safe(PdfGoogleFonts.openSansBoldItalic,
              pw.Font.helveticaBoldOblique()),
          mono: mono,
        );
      case 'Noto Serif':
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.notoSerifRegular, pw.Font.times()),
          bold: await safe(PdfGoogleFonts.notoSerifBold, pw.Font.timesBold()),
          italic:
              await safe(PdfGoogleFonts.notoSerifItalic, pw.Font.timesItalic()),
          boldItalic: await safe(
              PdfGoogleFonts.notoSerifBoldItalic, pw.Font.timesBoldItalic()),
          mono: mono,
        );
      case 'Roboto':
      default:
        return PdfFontSet(
          base: await safe(PdfGoogleFonts.robotoRegular, pw.Font.helvetica()),
          bold: await safe(PdfGoogleFonts.robotoBold, pw.Font.helveticaBold()),
          italic: await safe(
              PdfGoogleFonts.robotoItalic, pw.Font.helveticaOblique()),
          boldItalic: await safe(
              PdfGoogleFonts.robotoBoldItalic, pw.Font.helveticaBoldOblique()),
          mono: mono,
        );
    }
  }

  /// Font families offered in the profile editor.
  static const List<String> availableFonts = [
    'Inter',
    'Roboto',
    'Lato',
    'Open Sans',
    'Montserrat',
    'Merriweather',
    'Noto Serif',
  ];
}
