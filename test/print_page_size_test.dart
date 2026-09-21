import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/models/print_profile.dart';
import 'package:markdown_studio/services/print_service.dart';
import 'package:pdf/pdf.dart';

void main() {
  group('profile page size', () {
    test('Court Filing prints on US Letter, not A4', () {
      // US courts (Arkansas among them) file on Letter. A4 is 595.276 x 841.89.
      final format = PrintService.formatFor(PrintProfile.courtFiling.pageSize);
      expect(PrintProfile.courtFiling.pageSize, PrintPageSize.letter);
      expect(format.width, closeTo(612, 0.01));
      expect(format.height, closeTo(792, 0.01));
    });

    test('1 inch margins survive on Letter', () {
      // marginCm 2.54 is applied by print_service as marginCm * PdfPageFormat.cm.
      final margin = PrintProfile.courtFiling.marginCm * PdfPageFormat.cm;
      expect(margin, closeTo(PdfPageFormat.inch, 0.01)); // 72pt
      final page = PrintService.formatFor(PrintProfile.courtFiling.pageSize)
          .copyWith(
        marginLeft: margin,
        marginRight: margin,
        marginTop: margin,
        marginBottom: margin,
      );
      // 8.5in - 2x1in = 6.5in of printable width, 9in of height.
      expect(page.availableWidth, closeTo(6.5 * PdfPageFormat.inch, 0.01));
      expect(page.availableHeight, closeTo(9 * PdfPageFormat.inch, 0.01));
    });

    test('other built-ins keep A4', () {
      expect(PrintProfile.personal.pageSize, PrintPageSize.a4);
      expect(PrintProfile.work.pageSize, PrintPageSize.a4);
    });

    test('formatFor maps every size', () {
      expect(PrintService.formatFor(PrintPageSize.a4).width,
          closeTo(PdfPageFormat.a4.width, 0.01));
      expect(PrintService.formatFor(PrintPageSize.legal).height,
          closeTo(14 * PdfPageFormat.inch, 0.01));
    });
  });

  group('page size round-trips through JSON', () {
    test('explicit size survives encode/decode', () {
      const p = PrintProfile(
          id: 'x', name: 'X', pageSize: PrintPageSize.letter);
      final back = PrintProfile.fromJson(p.toJson());
      expect(back.pageSize, PrintPageSize.letter);
    });

    test('a profile saved before page size existed defaults to A4', () {
      // Back-compat: profiles already on disk have no "pageSize" key, and have
      // always rendered at A4 — they must keep doing so.
      final json = PrintProfile.personal.toJson()..remove('pageSize');
      expect(PrintProfile.fromJson(json).pageSize, PrintPageSize.a4);
    });

    test('an unrecognised size falls back to A4 rather than throwing', () {
      final json = PrintProfile.personal.toJson()..['pageSize'] = 'tabloid';
      expect(PrintProfile.fromJson(json).pageSize, PrintPageSize.a4);
    });

    test('copyWith carries the size', () {
      final p = PrintProfile.personal.copyWith(pageSize: PrintPageSize.legal);
      expect(p.pageSize, PrintPageSize.legal);
      expect(PrintProfile.personal.pageSize, PrintPageSize.a4); // unchanged
    });
  });
}
