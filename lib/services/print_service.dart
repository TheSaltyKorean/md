import 'dart:async' show TimeoutException;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

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
    final remoteImages = await _fetchRemoteImages(markdown);
    final margin = profile.marginCm * PdfPageFormat.cm;
    // Height available to body content on one page (page minus margins, with
    // an allowance for the running header/footer). Used to cap image height
    // so a tall image scales to fit rather than overflowing the page.
    final contentHeight =
        (format.height - 2 * margin - 80).clamp(144.0, double.infinity);
    final builder = MarkdownPdfBuilder(
      profile: profile,
      fonts: fonts,
      baseDir: baseDir,
      maxImageHeight: contentHeight,
      remoteImages: remoteImages,
    );
    final content = builder.build(markdown);

    // Brand "cover" mode: the logo appears once at the top of the document
    // (not as a running header), like a branded cover sheet.
    final useCover = profile.coverLogo && logo != null;
    final body = <pw.Widget>[
      if (useCover) _coverLogo(logo),
      ...content,
    ];

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
        // In cover mode the logo is rendered once at the top of the body, so the
        // running header omits the logo and the (now-redundant) company name —
        // the cover logo already conveys the brand. The header is still kept so
        // any title, classification label and accent rule appear on every page.
        header: (context) => _header(
            context, profile, title, useCover ? null : logo,
            hideCompany: useCover),
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
    pw.MemoryImage? logo, {
    bool hideCompany = false,
  }) {
    // Legal mode prints monochrome: the header chrome (company name, badge fill,
    // accent rule) uses the body text colour instead of the brand colour.
    final primary = PdfColor.fromInt(
        profile.legalMode ? profile.textColor : profile.primaryColor);

    final brandRow = <pw.Widget>[];
    if (logo != null) {
      brandRow.add(pw.Container(height: 26, child: pw.Image(logo)));
    }
    if (!hideCompany &&
        profile.companyName != null &&
        profile.companyName!.isNotEmpty) {
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
              // Legal mode keeps the header title monochrome (body colour).
              style: pw.TextStyle(
                  fontSize: 9,
                  color: profile.legalMode ? primary : PdfColors.grey600),
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
    // Monochrome footer text in legal mode (see _header).
    final primary = PdfColor.fromInt(
        profile.legalMode ? profile.textColor : profile.primaryColor);

    // Brand footer: a single centred grey line with a hairline rule above,
    // e.g. "Company — <Title> | Page N of M".
    if (profile.footerCentered) {
      final bits = <String>[];
      if (profile.footerText != null && profile.footerText!.isNotEmpty) {
        bits.add(profile.footerText!);
      }
      if (title.isNotEmpty) bits.add(title);
      if (profile.showDate) bits.add(_today());
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
          // Legal mode prints the footer in the body colour; otherwise the
          // centred footer keeps its subtle grey.
          style: pw.TextStyle(
              fontSize: 7.5,
              color: profile.legalMode
                  ? primary
                  : const PdfColor.fromInt(0xFF8A8DA0)),
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
              // Legal mode prints date/page numbers in the body colour too;
              // otherwise they stay subtle grey.
              style: pw.TextStyle(
                  fontSize: 8,
                  color: profile.legalMode ? primary : PdfColors.grey600),
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

  /// Hard ceiling for one downloaded image. Big enough for any sane photo,
  /// small enough that a document pointing at a huge file degrades to the
  /// placeholder instead of ballooning memory during preview/export.
  static const int _maxRemoteImageBytes = 20 * 1024 * 1024;

  /// Aggregate budget across all of a document's images: once spent, the
  /// remaining images render placeholders, so a photo-heavy document
  /// degrades instead of holding hundreds of MB before PDF generation.
  static const int _maxTotalRemoteImageBytes = 100 * 1024 * 1024;

  /// Downloads run through a small worker pool instead of all at once, so a
  /// document with many images can't open hundreds of sockets.
  static const int _maxConcurrentImageFetches = 4;

  /// Download the document's `https` images up front — [MarkdownPdfBuilder]
  /// builds synchronously, so network content must be pre-fetched (the same
  /// pattern as fonts). Failures are dropped: a missing entry renders as the
  /// builder's placeholder instead of failing the whole print. Each image is
  /// bounded twice — a whole-task timeout (covering DNS/connect, which stage
  /// timeouts alone would not) and a byte cap — so one unreachable host or
  /// huge file can't hang or exhaust the print.
  Future<Map<String, Uint8List>> _fetchRemoteImages(String markdown) async {
    final sources = MarkdownPdfBuilder.remoteImageSources(markdown).toList();
    if (sources.isEmpty) return const {};
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final result = <String, Uint8List>{};
    var budget = _maxTotalRemoteImageBytes;
    var next = 0;
    // Fixed pool of sequential workers. Dart's event loop makes the shared
    // index/budget updates race-free; only stored bytes count against the
    // budget, so the retained total never exceeds it.
    Future<void> worker() async {
      while (next < sources.length && budget > 0) {
        final src = sources[next++];
        final limit =
            budget < _maxRemoteImageBytes ? budget : _maxRemoteImageBytes;
        try {
          // The deadline lives inside _fetchOne (not a Future.timeout
          // wrapper, which completes the wrapper but leaves the download
          // streaming in the background, silently exceeding the pool and
          // byte bounds).
          final bytes = await _fetchOne(client, src, limit);
          if (bytes.length <= budget) {
            result[src] = bytes;
            budget -= bytes.length;
          }
        } catch (_) {/* unreachable/oversized image -> placeholder */}
      }
    }

    try {
      await Future.wait(
          List.generate(_maxConcurrentImageFetches, (_) => worker()));
    } finally {
      client.close();
    }
    return result;
  }

  Future<Uint8List> _fetchOne(
      HttpClient client, String src, int maxBytes) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw const HttpException('fetch deadline');
      return left;
    }

    // Redirects are followed manually so every hop stays HTTPS — the
    // default auto-follow would happily hop to a cleartext http target,
    // bypassing the https-only policy for anything hosted behind a
    // redirect.
    var uri = Uri.parse(src);
    var redirects = 0;
    HttpClientResponse response;
    while (true) {
      final request = await client.getUrl(uri).timeout(remaining());
      request.followRedirects = false;
      try {
        response = await request.close().timeout(remaining());
      } on TimeoutException {
        request.abort(); // actually tear the request down, don't just move on
        rethrow;
      }
      if (!response.isRedirect) break;
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (location == null || ++redirects > 5) {
        throw const HttpException('bad redirect');
      }
      uri = uri.resolve(location);
      if (uri.scheme.toLowerCase() != 'https') {
        throw const HttpException('redirect left https');
      }
    }
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    if (response.contentLength > maxBytes) {
      throw const HttpException('image exceeds size cap');
    }
    final bytes = BytesBuilder();
    // Stream.timeout bounds each inter-chunk gap and — unlike a
    // Future.timeout around the whole fetch — cancels the subscription when
    // it fires, so a slow-dripping server can't keep the download alive in
    // the background. The deadline check bounds total elapsed time; a throw
    // out of await-for also cancels the subscription.
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (DateTime.now().isAfter(deadline)) {
        throw const HttpException('fetch deadline');
      }
      bytes.add(chunk);
      // Content-Length can lie (or be absent): enforce the cap on the
      // actually accumulated bytes too.
      if (bytes.length > maxBytes) {
        throw const HttpException('image exceeds size cap');
      }
    }
    return bytes.takeBytes();
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

  /// Font families offered in the profile editor. Roboto stays first because it
  /// is the resolver's fallback for any unrecognised family, so the editor's
  /// default selection matches what an unsupported profile actually renders.
  static const List<String> availableFonts = [
    'Roboto',
    'Inter',
    'Lato',
    'Open Sans',
    'Montserrat',
    'Merriweather',
    'Noto Serif',
  ];
}
