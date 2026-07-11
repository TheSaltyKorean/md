import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/material.dart'
    show
        DropdownButtonFormField,
        IconButton,
        MaterialApp,
        GestureDetector,
        PopupMenuButton,
        Scaffold,
        SelectionArea,
        Text,
        TextDecoration,
        TextField;
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, MethodCall, SystemChannels;
import 'package:flutter/widgets.dart'
    show
        Axis,
        MediaQuery,
        SingleChildScrollView,
        Size,
        SizedBox,
        TextScaler,
        TextSelection,
        Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_studio/app.dart';
import 'package:markdown_studio/models/editor_mode.dart';
import 'package:markdown_studio/models/print_profile.dart';
import 'package:markdown_studio/services/file_association_service.dart';
import 'package:markdown_studio/services/markdown_pdf_builder.dart';
import 'package:markdown_studio/services/print_profile_service.dart';
import 'package:markdown_studio/services/update_service.dart';
import 'package:markdown_studio/state/document_controller.dart';
import 'package:markdown_studio/state/theme_controller.dart';
import 'package:markdown_studio/services/session_service.dart';
import 'package:markdown_studio/state/workspace_controller.dart';
import 'package:markdown_studio/state/zoom_controller.dart';
import 'package:markdown_studio/widgets/find_controller.dart';
import 'package:markdown_studio/widgets/preview_find_view.dart';
import 'package:markdown_studio/widgets/preview_view.dart';
import 'package:markdown_studio/widgets/print_preview_view.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pdf/pdf.dart' show PdfColors, PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Standard built-in PDF fonts, so PDF-render tests never touch the network.
PdfFontSet _standardFonts() => PdfFontSet(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      italic: pw.Font.helveticaOblique(),
      boldItalic: pw.Font.helveticaBoldOblique(),
      mono: pw.Font.courier(),
    );

/// Walk the layout-widget tree (the container types the builder emits) so tests
/// can assert structure without rendering.
Iterable<pw.Widget> _allWidgets(pw.Widget w) sync* {
  yield w;
  if (w is pw.Padding && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.SizedBox && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Align && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Container && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Column) {
    for (final c in w.children) {
      yield* _allWidgets(c);
    }
  } else if (w is pw.Row) {
    for (final c in w.children) {
      yield* _allWidgets(c);
    }
  } else if (w is pw.ConstrainedBox && w.child != null) {
    yield* _allWidgets(w.child!);
  } else if (w is pw.Table) {
    for (final row in w.children) {
      for (final c in row.children) {
        yield* _allWidgets(c);
      }
    }
  }
}

/// All literal text reachable from the given widgets' RichText spans.
String _literalText(Iterable<pw.Widget> ws) {
  final sb = StringBuffer();
  void walkSpan(pw.InlineSpan s) {
    if (s is pw.TextSpan) {
      if (s.text != null) sb.write(s.text);
      for (final c in s.children ?? const <pw.InlineSpan>[]) {
        walkSpan(c);
      }
    }
  }

  for (final w in ws) {
    if (w is pw.RichText) walkSpan(w.text);
  }
  return sb.toString();
}

Iterable<pw.Widget> _walk(List<pw.Widget> ws) => ws.expand(_allWidgets);

/// Lay [widgets] into an A4 MultiPage with 2cm margins and return the bytes —
/// throws if any single widget can't fit/paginate (the bug these tests guard).
Future<Uint8List> _renderA4(List<pw.Widget> widgets) async {
  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.copyWith(
      marginLeft: 2 * PdfPageFormat.cm,
      marginRight: 2 * PdfPageFormat.cm,
      marginTop: 2 * PdfPageFormat.cm,
      marginBottom: 2 * PdfPageFormat.cm,
    ),
    build: (_) => widgets,
  ));
  return doc.save();
}

void main() {
  testWidgets('App boots and shows the mode selector', (tester) async {
    // Desktop-sized surface (this is a desktop-first app; the default 800x600
    // test surface is narrower than any real window).
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Pre-decide the association prompt so the boot stays hermetic (no OS calls).
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
          ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ChangeNotifierProvider(
              create: (_) =>
                  UpdateController(prefs, fetchLatestTag: () async => null)),
          ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
          ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
          Provider(create: (_) => FileAssociationService(prefs)),
        ],
        child: const MarkdownStudioApp(),
      ),
    );
    await tester.pumpAndSettle();

    // The mode toggle is icon-only; each segment carries a tooltip naming it.
    expect(find.byTooltip('Edit'), findsOneWidget);
    expect(find.byTooltip('Split'), findsOneWidget);
    expect(find.byTooltip('Raw'), findsOneWidget);
    expect(find.byTooltip('Preview'), findsOneWidget);
  });

  testWidgets('About shows the real build version, not a hardcoded one',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();
    // The version the platform reports — deliberately unlike any release.
    PackageInfo.setMockInitialValues(
      appName: 'Markdown Studio',
      packageName: 'com.markdownstudio.markdown_studio',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
          ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ChangeNotifierProvider(
              create: (_) =>
                  UpdateController(prefs, fetchLatestTag: () async => null)),
          ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
          ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
          Provider(create: (_) => FileAssociationService(prefs)),
        ],
        child: const MarkdownStudioApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('9.9.9'), findsOneWidget);
  });

  testWidgets('Selecting a profile in the preview is saved with the document',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);
    // Wide enough that the full toolbar (incl. the zoom controls) lays out
    // without scrolling, so the pin button is on-screen for the tap below.
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pump(String? docPath) => tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
            ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        ));

    await pump('/tmp/a.md');
    await tester.pump(const Duration(seconds: 1));

    // Choosing a profile in the dropdown IS the association — no pin needed.
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Work').last);
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a.md'), 'work');

    // It survives a restart (fresh service over the same prefs).
    await service.pendingWrites;
    expect(PrintProfileService(prefs).forDocument('/tmp/a.md').id, 'work');

    // The pin now clears the association.
    await tester.tap(find
        .byTooltip('Always using this profile for this file — tap to stop'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a.md'), isNull);

    // And an explicit clear is final: a later Save As must not resurrect
    // the association the user just removed.
    await pump('/tmp/a-renamed.md');
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/a-renamed.md'), isNull);
  });

  testWidgets('A profile chosen for an unsaved doc sticks after Save As',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    Widget app(String? docPath) => MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
            ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        );

    // Unsaved: selection is session-local (nothing durable to key on).
    await tester.pumpWidget(app(null));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Work').last);
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString('doc_print_profile_map'), isNull);

    // Save As + print again: same preview, now with a path — the chosen
    // profile is remembered for the file.
    await tester.pumpWidget(app('/tmp/b.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/b.md'), 'work');
  });

  testWidgets('Save As never pins a default the user did not choose',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    Widget app(String? docPath) => MultiProvider(
          providers: [
            ChangeNotifierProvider<PrintProfileService>.value(value: service),
            ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: PrintPreviewView(
                  markdown: '# Hello', title: 'a', docPath: docPath),
            ),
          ),
        );

    // Preview an unsaved doc without ever touching the dropdown, then
    // Save As: the (default) profile must NOT become a file binding — the
    // document keeps following future default changes.
    await tester.pumpWidget(app(null));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app('/tmp/c.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/c.md'), isNull);

    // But an existing binding follows the document through Save As to a new
    // path, even with no in-session selection. (Fresh preview, as the app
    // would create for the already-bound document.)
    await tester.pumpWidget(const SizedBox());
    await service.assignToDocument('/tmp/d.md', 'work');
    await tester.pumpWidget(app('/tmp/d.md'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(app('/tmp/e.md'));
    await tester.pump(const Duration(seconds: 1));
    expect(service.assignedId('/tmp/e.md'), 'work');
  });

  testWidgets('Preview zoom controls are reachable (tappable) at phone width',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);
    final zoom = ZoomController(prefs);
    // Phone portrait: the action row scrolls, but the zoom cluster is pinned
    // outside that scroll so it must be on-screen and hittable without any
    // horizontal scrolling of the toolbar.
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PrintProfileService>.value(value: service),
        ChangeNotifierProvider<ZoomController>.value(value: zoom),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: PrintPreviewView(markdown: '# Hi', title: 'a', docPath: null),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('Zoom in'), findsOneWidget);
    // A default tap warns (and won't register) if the button is off-screen or
    // obscured — so a real factor bump proves the pinned control is reachable.
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(zoom.factor, greaterThan(1.0));
  });

  test('Association repair: installed copies reclaim, dev builds never', () {
    const pf = r'C:\Program Files';
    const pf86 = r'C:\Program Files (x86)';
    const installedExe =
        r'C:\Program Files\Markdown Studio\markdown_studio.exe';
    const devExe = r'C:\git\md\build\windows\x64\runner\Release'
        r'\markdown_studio.exe';

    // Installed copy + registration pointing at a dev build → repair.
    expect(
        FileAssociationService.needsRepair(
          exe: installedExe,
          programDirs: const [pf, pf86],
          registeredCommand: '(Default)    REG_SZ    "$devExe" "%1"',
        ),
        isTrue);

    // Registration already points at this installed copy → leave alone
    // (case-insensitive, as the registry is).
    expect(
        FileAssociationService.needsRepair(
          exe: installedExe,
          programDirs: const [pf, pf86],
          registeredCommand:
              '(Default)    REG_SZ    "${installedExe.toUpperCase()}" "%1"',
        ),
        isFalse);

    // A dev build must never steal the association back.
    expect(
        FileAssociationService.needsRepair(
          exe: devExe,
          programDirs: const [pf, pf86],
          registeredCommand: '(Default)    REG_SZ    "$installedExe" "%1"',
        ),
        isFalse);

    // Never registered → nothing to repair.
    expect(
        FileAssociationService.needsRepair(
          exe: installedExe,
          programDirs: const [pf, pf86],
          registeredCommand: null,
        ),
        isFalse);

    // The per-user install root (since 1.0.9) also counts as installed and
    // reclaims a stale association.
    const perUser = r'C:\Users\r\AppData\Local\Programs';
    const perUserExe =
        r'C:\Users\r\AppData\Local\Programs\Markdown Studio\markdown_studio.exe';
    expect(
        FileAssociationService.needsRepair(
          exe: perUserExe,
          programDirs: const [perUser, pf, pf86],
          registeredCommand: '(Default)    REG_SZ    "$devExe" "%1"',
        ),
        isTrue);
  });

  test('Zoom controller steps, clamps, snaps, and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final zoom = ZoomController(prefs);

    expect(zoom.factor, 1.0);
    expect(zoom.label, '100%');

    zoom.zoomIn();
    expect(zoom.factor, 1.1);
    zoom.zoomOut();
    // Snapped to the step grid — no floating-point drift away from 100%.
    expect(zoom.factor, 1.0);

    for (var i = 0; i < 40; i++) {
      zoom.zoomIn();
    }
    expect(zoom.factor, ZoomController.maxFactor);
    expect(zoom.canZoomIn, isFalse);

    for (var i = 0; i < 40; i++) {
      zoom.zoomOut();
    }
    expect(zoom.factor, ZoomController.minFactor);
    expect(zoom.canZoomOut, isFalse);

    zoom.reset();
    expect(zoom.factor, 1.0);
    zoom.zoomIn();
    zoom.zoomIn();
    await zoom.pendingWrites;

    // A fresh controller (new launch) restores the persisted factor.
    expect(ZoomController(prefs).factor, 1.2);

    // The composed scaler multiplies the inherited (accessibility) scale by
    // the zoom, exposes the inherited part for chrome to opt back out, and
    // compares by value so MediaQuery equality checks work across rebuilds.
    const zs = ZoomedTextScaler(TextScaler.linear(1.5), 1.2);
    expect(zs.scale(10), moreOrLessEquals(18.0));
    expect(zs.inherited.scale(10), moreOrLessEquals(15.0));
    expect(zs, const ZoomedTextScaler(TextScaler.linear(1.5), 1.2));
  });

  testWidgets('Ctrl +/-/0 zooms the document views', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
          ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ChangeNotifierProvider(
              create: (_) =>
                  UpdateController(prefs, fetchLatestTag: () async => null)),
          ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
          ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
          Provider(create: (_) => FileAssociationService(prefs)),
        ],
        child: const MarkdownStudioApp(),
      ),
    );
    await tester.pumpAndSettle();

    final zoom = Provider.of<ZoomController>(
        tester.element(find.byType(MarkdownStudioApp)),
        listen: false);

    Future<void> combo(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    await combo(LogicalKeyboardKey.equal);
    expect(zoom.factor, 1.1);
    await combo(LogicalKeyboardKey.minus);
    await combo(LogicalKeyboardKey.minus);
    expect(zoom.factor, 0.9);
    await combo(LogicalKeyboardKey.digit0);
    expect(zoom.factor, 1.0);

    // The document view scales with the zoom (ambient text scaler). A fresh
    // document opens in Preview mode, so that's the mounted view.
    zoom.zoomIn();
    await tester.pumpAndSettle();
    final scaler = MediaQuery.of(
      tester.element(find.byType(PreviewView)),
    ).textScaler;
    expect(scaler.scale(10), moreOrLessEquals(11.0));

    // Zoom composes with (never replaces) the platform/accessibility text
    // scale: 10pt × 1.5 (platform) × 1.1 (zoom) = 16.5.
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    final composed = MediaQuery.of(
      tester.element(find.byType(PreviewView)),
    ).textScaler;
    expect(composed.scale(10), moreOrLessEquals(16.5));
    tester.platformDispatcher.clearTextScaleFactorTestValue();

    // While zoomed, a "110%" chip appears in the toolbar as persistent
    // feedback; clicking it resets to 100% and it disappears.
    expect(find.text('110%'), findsOneWidget);
    await tester.tap(find.text('110%'));
    await tester.pumpAndSettle();
    expect(zoom.factor, 1.0);
    expect(find.text('100%'), findsNothing);

    // On a print-preview tab the same zoom drives the preview page width
    // (user request) — the shortcuts stay live there.
    zoom.reset();
    final ws = Provider.of<WorkspaceController>(
        tester.element(find.byType(MarkdownStudioApp)),
        listen: false);
    ws.openPrintPreview(markdown: '# sample', title: 'sample', docPath: null);
    // Plain pumps: PdfPreview keeps scheduling frames while it renders, so
    // pumpAndSettle would never settle here.
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(zoom.factor, 1.1);
    zoom.reset();
    await tester.pump();
  });

  testWidgets('Two-finger pinch zooms; one-finger drag does not',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
        ChangeNotifierProvider(
            create: (_) =>
                UpdateController(prefs, fetchLatestTag: () async => null)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
        Provider(create: (_) => FileAssociationService(prefs)),
      ],
      child: const MarkdownStudioApp(),
    ));
    await tester.pumpAndSettle();

    final zoom = Provider.of<ZoomController>(
        tester.element(find.byType(MarkdownStudioApp)),
        listen: false);
    expect(zoom.factor, 1.0);

    // Two fingers 100px apart, spread to 150px → 1.5x zoom.
    final center = tester.getCenter(find.byType(PreviewView));
    final f1 = await tester.startGesture(center - const Offset(50, 0));
    final f2 = await tester.startGesture(center + const Offset(50, 0));
    await tester.pump();
    await f1.moveBy(const Offset(-25, 0));
    await f2.moveBy(const Offset(25, 0));
    await tester.pump();
    await f1.up();
    await f2.up();
    await tester.pumpAndSettle();
    expect(zoom.factor, moreOrLessEquals(1.5));

    // A one-finger drag must NOT zoom (the Listener observes without claiming
    // the gesture, so scrolling is unaffected).
    zoom.reset();
    await tester.pumpAndSettle();
    final drag = await tester.startGesture(center);
    await drag.moveBy(const Offset(0, -80));
    await drag.up();
    await tester.pumpAndSettle();
    expect(zoom.factor, 1.0);
  });

  testWidgets('Pinch re-baselines when a third finger changes the pair',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
        ChangeNotifierProvider(
            create: (_) =>
                UpdateController(prefs, fetchLatestTag: () async => null)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
        Provider(create: (_) => FileAssociationService(prefs)),
      ],
      child: const MarkdownStudioApp(),
    ));
    await tester.pumpAndSettle();
    final zoom = Provider.of<ZoomController>(
        tester.element(find.byType(MarkdownStudioApp)),
        listen: false);

    // Two fingers 100px apart (baseline). Add a third, then lift one of the
    // ORIGINAL pair, leaving a new, much wider pair (f2..f3 = 300px). The next
    // small move must scale against that 300px baseline — not the stale 100px,
    // which would slam the zoom to its 3.0 ceiling.
    final f1 = await tester.startGesture(const Offset(100, 400));
    final f2 = await tester.startGesture(const Offset(200, 400));
    await tester.pump();
    final f3 = await tester.startGesture(const Offset(500, 400));
    await tester.pump();
    await f1.up(); // remaining pair f2(200) + f3(500) → re-baseline at 300px
    await tester.pump();
    await f3.moveBy(const Offset(100, 0)); // pair now 400px → 400/300 ≈ 1.33x
    await tester.pump();
    expect(zoom.factor, lessThan(2.0)); // ~1.3, not the stale-baseline 3.0
    await f2.up();
    await f3.up();
    await tester.pumpAndSettle();
  });

  testWidgets('Phone layout: mode toggle and icons share the second row',
      (tester) async {
    // Narrow width triggers the stacked layout: the tab strip owns the top
    // row; the mode toggle and action icons share the second row.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
        ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
        ChangeNotifierProvider(
            create: (_) =>
                UpdateController(prefs, fetchLatestTag: () async => null)),
        ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
        ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
        Provider(create: (_) => FileAssociationService(prefs)),
      ],
      child: const MarkdownStudioApp(),
    ));
    await tester.pumpAndSettle();

    // The Save icon sits BELOW the top app-bar row (second row, not crammed
    // next to the tabs). kToolbarHeight = 56.
    final save = find.byTooltip('Save');
    expect(save, findsOneWidget);
    expect(tester.getCenter(save).dy, greaterThan(56.0));

    // The mode toggle shares that same row as the icons — same vertical
    // centre, not stacked on a separate line. Locate it by its 'Raw' segment
    // tooltip (a mode label that doesn't collide with other chrome).
    final mode = find.byTooltip('Raw');
    expect(mode, findsOneWidget);
    expect(tester.getCenter(mode).dy,
        moreOrLessEquals(tester.getCenter(save).dy, epsilon: 2.0));
  });

  test('Update version comparison is strict and parse-safe', () {
    expect(UpdateController.isNewer('1.0.5', '1.0.4'), isTrue);
    expect(UpdateController.isNewer('1.1.0', '1.0.9'), isTrue);
    expect(UpdateController.isNewer('2.0.0', '1.9.9'), isTrue);
    expect(UpdateController.isNewer('1.0.4', '1.0.4'), isFalse);
    expect(UpdateController.isNewer('1.0.3', '1.0.4'), isFalse);
    expect(UpdateController.isNewer('not-a-version', '1.0.4'), isFalse);
    // Anchored: numeric-prefixed garbage must not read as a version.
    expect(UpdateController.isNewer('9.9.9oops', '1.0.4'), isFalse);
    // …but a '+build' suffix is real-world (Windows ProductVersion is
    // '1.0.5+6') and must parse — this silently killed all update checks.
    expect(UpdateController.isNewer('1.0.6', '1.0.5+6'), isTrue);
    expect(UpdateController.isNewer('1.0.5+7', '1.0.5+6'), isFalse);
    expect(UpdateController.isNewer('1.0.5', 'garbage'), isFalse);
  });

  test('Install-kind detection routes each channel to its own updater', () {
    const env = {
      'LocalAppData': r'C:\Users\r\AppData\Local',
      'ProgramFiles': r'C:\Program Files',
      'ProgramFiles(x86)': r'C:\Program Files (x86)',
    };
    InstallKind win(String exe, {bool inno = false}) =>
        UpdateController.detectInstallKind(
            exe: exe,
            env: env,
            isWindows: true,
            isLinux: false,
            hasInnoUninstaller: inno);
    // Since 1.0.9 the per-user install lives under %LocalAppData%\Programs.
    const installed = r'C:\Users\r\AppData\Local\Programs\Markdown Studio'
        r'\markdown_studio.exe';
    expect(win(installed), InstallKind.msi);
    // A setup.exe (Inno) install lands in the SAME directory but leaves its
    // unins000.exe — it must get the setup.exe updater, never the MSI.
    expect(win(installed, inno: true), InstallKind.inno);
    // A legacy per-machine Program Files copy is NOT one-click: a per-user
    // MSI can't upgrade it in place, so it routes to the download page for
    // the one-time manual migration.
    expect(win(r'C:\Program Files\Markdown Studio\markdown_studio.exe'),
        InstallKind.other);
    // A Store (MSIX) package lives under Program Files\WindowsApps and must
    // take no installer path at all.
    expect(
        win(r'C:\Program Files\WindowsApps\12345.MarkdownStudio_1.0.5.0_x64'
            r'\markdown_studio.exe'),
        InstallKind.other);
    expect(win(r'C:\Users\r\Downloads\portable\markdown_studio.exe'),
        InstallKind.other);

    InstallKind linux(String exe) => UpdateController.detectInstallKind(
        exe: exe,
        env: const {},
        isWindows: false,
        isLinux: true,
        hasInnoUninstaller: false);
    expect(linux('/opt/markdown-studio/markdown_studio'), InstallKind.deb);
    expect(linux('/home/r/apps/markdown_studio'), InstallKind.other);
    expect(InstallKind.other.canOneClick, isFalse);
    expect(InstallKind.inno.canOneClick, isTrue);
  });

  test('Windows launcher waits for pid, installs silently, relaunches', () {
    const exe = r'C:\Users\r\AppData\Local\Programs\Markdown Studio'
        r'\markdown_studio.exe';
    final msi = UpdateController.windowsLauncherScript(
      waitForPid: 4242,
      installerCommand:
          r'msiexec /i "C:\Temp Dir\update.msi" /passive /norestart',
      relaunchExe: exe,
    );
    // Waits for OUR pid to be gone before anything runs.
    expect(msi, contains('ProcessId = 4242'));
    expect(msi, contains('WScript.Sleep'));
    // Runs the installer and WAITS for it (bWaitOnReturn = True), then
    // relaunches — the whole update completes hands-off.
    expect(msi,
        contains(r'sh.Run "msiexec /i ""C:\Temp Dir\update.msi"" /passive'));
    expect(msi, contains(', 1, True'));
    // Relaunch line: the same-path exe, quoted, not waited on.
    expect(msi, contains('sh.Run """$exe""", 1, False'));

    final inno = UpdateController.windowsLauncherScript(
      waitForPid: 7,
      installerCommand: r'"C:\Temp Dir\setup.exe" /SILENT /SUPPRESSMSGBOXES',
      relaunchExe: exe,
    );
    expect(
        inno,
        contains(
            r'sh.Run """C:\Temp Dir\setup.exe"" /SILENT /SUPPRESSMSGBOXES'));
  });

  test('Update check finds newer releases and honors the toggle', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'Markdown Studio',
      packageName: 'com.markdownstudio.markdown_studio',
      version: '1.0.4',
      buildNumber: '5',
      buildSignature: '',
      installerStore: null,
    );

    var fetches = 0;
    final updates = UpdateController(prefs, fetchLatestTag: () async {
      fetches++;
      return 'v9.9.9';
    });
    expect(await updates.check(), isTrue);
    expect(updates.available!.version, '9.9.9');

    // Same-version tag: no update offered.
    final same = UpdateController(prefs, fetchLatestTag: () async => 'v1.0.4');
    expect(await same.check(), isFalse);
    expect(same.available, isNull);

    // Toggle off: the startup check never even fetches.
    updates.setCheckOnStartup(false);
    await updates.pendingWrites;
    final before = fetches;
    expect(await updates.check(), isFalse);
    expect(fetches, before);
    // …but a manual check bypasses the toggle.
    expect(await updates.check(respectToggle: false), isTrue);
    // The preference persists like the others.
    expect(UpdateController(prefs).checkOnStartup, isFalse);
  });

  testWidgets('An available update surfaces as a toolbar chip', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'assoc_prompt_done': true});
    final prefs = await SharedPreferences.getInstance();
    PackageInfo.setMockInitialValues(
      appName: 'Markdown Studio',
      packageName: 'com.markdownstudio.markdown_studio',
      version: '1.0.4',
      buildNumber: '5',
      buildSignature: '',
      installerStore: null,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeController(prefs)),
          ChangeNotifierProvider(create: (_) => ZoomController(prefs)),
          ChangeNotifierProvider(
              create: (_) => UpdateController(prefs,
                  fetchLatestTag: () async => 'v9.9.9')),
          ChangeNotifierProvider(create: (_) => PrintProfileService(prefs)),
          ChangeNotifierProvider(create: (_) => WorkspaceController(prefs)),
          Provider(create: (_) => FileAssociationService(prefs)),
        ],
        child: const MarkdownStudioApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update to 9.9.9'), findsOneWidget);
    // The launch check also surfaces an explicit notification, not just
    // the chip (field feedback: the chip alone went unnoticed).
    expect(find.text('Markdown Studio 9.9.9 is available.'), findsOneWidget);
  });

  testWidgets('Preview is wrapped in a SelectionArea for document selection',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PreviewView(markdown: '# Hi\n\nSome prose.')),
    ));
    await tester.pumpAndSettle();
    // Unified selection across the whole document (not per-block).
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('Preview find highlights query occurrences in the render',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: 'A Contractor signs. Another contractor waits.',
          highlightQuery: 'contractor',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // Each occurrence (case-insensitive) is split into its own Text fragment
    // preserving the original case.
    expect(find.text('Contractor'), findsOneWidget);
    expect(find.text('contractor'), findsOneWidget);
    // The fragment carries a background highlight paint.
    final frag = tester.widget<Text>(find.text('Contractor'));
    expect(frag.style?.background, isNotNull);
  });

  testWidgets('Preview find: no highlight when the query is empty',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: 'A Contractor signs here.',
          highlightQuery: '',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // No split-out fragment: 'Contractor' stays embedded in its paragraph.
    expect(find.text('Contractor'), findsNothing);
  });

  testWidgets('Preview find bar: type query → count, highlights, navigation',
      (tester) async {
    final fc = FindController();
    addTearDown(fc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewFindView(
          // 'Zeta' (uppercase) appears 3x; the query is lowercase 'zeta', so
          // the highlighted fragments don't collide with the query field text.
          markdown: 'Zeta beta Zeta gamma Zeta done.',
          find: fc,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // No bar until find is opened.
    expect(find.byType(TextField), findsNothing);

    fc.openFind();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zeta');
    await tester.pumpAndSettle();

    // 3 case-insensitive occurrences; counter starts at 1/3.
    expect(find.text('1/3'), findsOneWidget);
    // Each occurrence is a highlighted fragment (original case preserved).
    expect(find.text('Zeta'), findsNWidgets(3));

    // Next advances the current match.
    await tester.tap(find.byTooltip('Next (Enter)'));
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);

    // Previous from 2/3 wraps back to 1/3.
    await tester.tap(find.byTooltip('Previous (Shift+Enter)'));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    // Close hides the bar.
    await tester.tap(find.byTooltip('Close (Esc)'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('Preview find excludes matches inside code fences',
      (tester) async {
    final fc = FindController();
    addTearDown(fc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewFindView(
          // 'Widget' appears once in prose and once in a fenced code block;
          // the code fence isn't highlighted, so it must not be counted.
          markdown: 'A real Widget here.\n\n```\nWidget in code\n```\n',
          find: fc,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    fc.openFind();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'widget');
    await tester.pumpAndSettle();
    // Only the prose occurrence counts (no phantom code-fence match).
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('Preview find counts rendered text, not link URLs',
      (tester) async {
    final fc = FindController();
    addTearDown(fc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewFindView(
          markdown: '[Docs](https://example.com/guide)',
          find: fc,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    fc.openFind();
    await tester.pumpAndSettle();
    // 'example' only appears in the link URL (not rendered) → no match.
    await tester.enterText(find.byType(TextField), 'example');
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);
    // 'Docs' is the rendered link label → one match.
    await tester.enterText(find.byType(TextField), 'docs');
    await tester.pumpAndSettle();
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('Preview find query "*" leaves bold rendering intact',
      (tester) async {
    final fc = FindController();
    addTearDown(fc.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewFindView(markdown: 'This is **bold** text.', find: fc),
      ),
    ));
    await tester.pumpAndSettle();
    fc.openFind();
    await tester.pumpAndSettle();
    // The asterisks are emphasis delimiters (consumed by parsing), not rendered
    // text — so the AST-level highlighter finds nothing and can't disturb the
    // bold. (The old inline-syntax approach wrapped the raw '*' and broke it.)
    await tester.enterText(find.byType(TextField), '*');
    await tester.pumpAndSettle();
    expect(find.text('No results'), findsOneWidget);
  });

  testWidgets('Preview find highlights text inside <u> underline',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: 'See <u>Important</u> notice.',
          highlightQuery: 'important',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The match inside the resolved <u> element is split out and highlighted.
    expect(find.text('Important'), findsOneWidget);
    final frag = tester.widget<Text>(find.text('Important'));
    expect(frag.style?.background, isNotNull);
  });

  testWidgets('Preview find matches a phrase across inline formatting',
      (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: 'the **Company** shall pay',
          highlightQuery: 'Company shall',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // "Company" (bold) and " shall" live in separate AST nodes but render as one
    // line, so the phrase matches and is split into two highlighted fragments.
    expect(count, 1);
    final company = tester.widget<Text>(find.text('Company'));
    expect(company.style?.background, isNotNull);
    final shall = tester.widget<Text>(find.text(' shall'));
    expect(shall.style?.background, isNotNull);
  });

  testWidgets('Preview find matches across a soft line break', (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          // Hard-wrapped paragraph: the soft break renders as a space.
          markdown: 'the Company\nshall pay',
          highlightQuery: 'Company shall',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(count, 1);
    // The highlighted run renders on one line (soft break normalised to space).
    final frag = tester.widget<Text>(find.text('Company shall'));
    expect(frag.style?.background, isNotNull);
  });

  testWidgets('Preview find collapses indentation after a soft break',
      (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          // Continuation line is indented; the renderer shows one space.
          markdown: 'the Company\n    shall pay',
          highlightQuery: 'Company shall',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(count, 1);
    expect(tester.widget<Text>(find.text('Company shall')).style?.background,
        isNotNull);
  });

  testWidgets('Preview find does not match across skipped inline code',
      (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          // Renders "foocodebar", but code sits between foo and bar.
          markdown: 'foo`code`bar',
          highlightQuery: 'foobar',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The rendered text foo…bar is not really contiguous, so no false match.
    expect(count, 0);
  });

  testWidgets('Preview find breaks the stream across inline-nested code',
      (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          // A bold span holds foo + code + bar, then plain baz follows. The
          // code break inside the bold must carry through so foo and baz are
          // not treated as contiguous.
          markdown: '**foo`code`bar**baz',
          highlightQuery: 'foobaz',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(count, 0);
  });

  testWidgets('Preview find keeps underline on highlighted <u> text',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: 'see <u>Important</u> here',
          highlightQuery: 'Important',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final frag = tester.widget<Text>(find.text('Important'));
    expect(frag.style?.background, isNotNull);
    // The <u> underline must survive under the highlight.
    expect(frag.style?.decoration, TextDecoration.underline);
  });

  testWidgets('Preview find does not match a phrase across block boundaries',
      (tester) async {
    var count = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: '# Section one\n\ntwo paragraphs',
          highlightQuery: 'one two',
          onMatchCount: (n) => count = n,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // "one" ends a heading and "two" starts a paragraph — different blocks, so
    // the visually-adjacent phrase must NOT match.
    expect(count, 0);
  });

  testWidgets('Preview find keeps a highlighted link label tappable',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(
          markdown: '[Docs](https://example.com)',
          highlightQuery: 'docs',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    // The highlighted 'Docs' fragment carries a tap handler (data-href), so the
    // link still works while find is open.
    final label = find.text('Docs');
    expect(label, findsOneWidget);
    expect(find.ancestor(of: label, matching: find.byType(GestureDetector)),
        findsWidgets);
  });

  testWidgets('Code blocks show a copy button that copies the block',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    const code = "void main() {\n  print('hi');\n}";
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PreviewView(markdown: 'Intro.\n\n```dart\n$code\n```\n'),
      ),
    ));
    await tester.pumpAndSettle();

    final button = find.byTooltip('Copy code');
    expect(button, findsOneWidget);

    // Long lines scroll horizontally rather than soft-wrapping.
    expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
        findsWidgets);

    await tester.tap(button);
    await tester.pump();

    final copied = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    // The exact block text, no fence markers and no trailing newline.
    expect((copied.arguments as Map)['text'], code);

    // The confirmation state flips to a check, then back.
    expect(find.byTooltip('Copied'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byTooltip('Copy code'), findsOneWidget);
  });

  testWidgets('Inline code does not get a copy button', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: PreviewView(markdown: 'A sentence with `inline` code.')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
  });

  test('Session restore round-trips tabs, unsaved buffers, and active tab',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore();
    final tmp = Directory.systemTemp.createTempSync('mdsess');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final one = File('${tmp.path}/one.md')..writeAsStringSync('# One');
    final two = File('${tmp.path}/two.md')..writeAsStringSync('# Two');

    final ws = WorkspaceController(prefs, sessionStore: store);
    ws.openDocument('# One', path: one.path);
    ws.openDocument('# Two', path: two.path);
    // Unsaved edit to a file-backed doc (editing needs a source mode).
    ws.documents[1].setMode(EditorMode.split);
    ws.documents[1].sourceController.text = '# Two edited';
    // A pathless, unsaved draft.
    ws.newDocument();
    ws.documents[2].setMode(EditorMode.raw);
    ws.documents[2].sourceController.text = 'draft notes';
    // Make the middle document the active one.
    ws.select(1);
    await ws.flushSession();
    expect(store.data, isNotNull);
    ws.dispose();

    // A fresh workspace (new launch) restores everything from the store.
    final ws2 = WorkspaceController(prefs, sessionStore: store);
    // Before restore it's just the blank starter tab.
    expect(ws2.documents.length, 1);
    await ws2.restoreSession();

    expect(ws2.documents.length, 3);
    expect(ws2.documents[0].currentMarkdown(), '# One');
    expect(ws2.documents[0].isDirty, isFalse);
    expect(ws2.documents[1].currentMarkdown(), '# Two edited');
    expect(ws2.documents[1].isDirty, isTrue); // unsaved edit preserved
    expect(ws2.documents[2].currentMarkdown(), 'draft notes');
    expect(ws2.documents[2].filePath, isNull); // pathless draft preserved
    // View modes round-trip too.
    expect(ws2.documents[1].mode, EditorMode.split);
    expect(ws2.documents[2].mode, EditorMode.raw);
    // The active document is restored too.
    expect(ws2.activeDocument, same(ws2.documents[1]));
    ws2.dispose();
  });

  test('Restore reflects a clean file changed on disk while closed', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore();
    final tmp = Directory.systemTemp.createTempSync('mdsess2');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/note.md')..writeAsStringSync('original');

    final ws = WorkspaceController(prefs, sessionStore: store);
    ws.openDocument('original', path: f.path); // clean, saved
    await ws.flushSession();
    ws.dispose();

    // The file changes on disk while the app is closed (git pull, sync…).
    f.writeAsStringSync('changed on disk');

    final ws2 = WorkspaceController(prefs, sessionStore: store);
    await ws2.restoreSession();
    // The clean tab shows the CURRENT file, not the stale saved buffer — so a
    // later save can't silently clobber the on-disk change.
    expect(ws2.documents.last.currentMarkdown(), 'changed on disk');
    expect(ws2.documents.last.isDirty, isFalse);
    ws2.dispose();
  });

  test('Restore is skipped when a document was already opened', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': null,
            'name': null,
            'content': 'saved',
            'dirty': true,
            'mode': 'raw'
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    // Simulate an OS file-association open before restore runs.
    ws.openDocument('# Opened via association', path: '/tmp/assoc.md');
    await ws.restoreSession();
    // The just-opened document is kept; the saved session did not clobber it.
    expect(ws.documents.length, 1);
    expect(ws.documents.first.currentMarkdown(), '# Opened via association');
    ws.dispose();
  });

  test('Restore re-surfaces an external conflict pending at shutdown',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessc1');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // The file on disk still holds the external content the conflict is about.
    final f = File('${tmp.path}/x.md')..writeAsStringSync('external content');
    // The persisted marker is only a flag; restore re-reads the CURRENT disk
    // to produce fresh conflict text (here written the old string way to prove
    // an old session is still read as "was conflicted").
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'my unsaved edits',
            'dirty': true,
            'mode': 'split',
            'synced': 'external content',
            'conflict': 'external content',
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.currentMarkdown(), 'my unsaved edits');
    expect(d.isDirty, isTrue);
    // The unresolved conflict is restored (from fresh disk), not dropped.
    expect(d.hasExternalConflict, isTrue);
    expect(d.pendingExternalContent, 'external content');
    ws.dispose();
  });

  test('Restore recomputes conflict text from the CURRENT file, not session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessc1b');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // The file changed AGAIN between shutdown and this launch: restore must
    // surface the newest disk content, never the stale text from session.json.
    final f = File('${tmp.path}/x.md')..writeAsStringSync('newest disk');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'my unsaved edits',
            'dirty': true,
            'mode': 'split',
            'synced': 'stale at shutdown',
            'conflict': true,
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.hasExternalConflict, isTrue);
    expect(d.pendingExternalContent, 'newest disk'); // fresh, not stale
    ws.dispose();
  });

  test('Restore drops the conflict when the file has caught up to the buffer',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessc1c');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // While closed, the file was edited to match the unsaved buffer — the
    // conflict has resolved itself, so restore must not resurface it.
    final f = File('${tmp.path}/x.md')..writeAsStringSync('my unsaved edits');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'my unsaved edits',
            'dirty': true,
            'mode': 'split',
            'synced': 'old disk',
            'conflict': true,
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.currentMarkdown(), 'my unsaved edits');
    expect(d.hasExternalConflict, isFalse);
    ws.dispose();
  });

  test('Restore keeps a conflict on a CLEAN doc (auto-reload off)', () async {
    // Auto-reload OFF: a clean tab whose file changed while closed must come
    // back with the old buffer and a Reload/Keep-mine conflict (not silently
    // adopt disk), mirroring the live watcher.
    SharedPreferences.setMockInitialValues({'auto_reload': false});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessc2');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/y.md')..writeAsStringSync('newer disk');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'saved buffer',
            'dirty': false, // clean, but with an unresolved external change
            'mode': 'preview',
            'conflict': true,
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.isDirty, isFalse); // stays clean…
    expect(d.currentMarkdown(), 'saved buffer'); // …with its buffer intact…
    expect(d.hasExternalConflict, isTrue); // …and the conflict preserved.
    expect(d.pendingExternalContent, 'newer disk');
    // Baseline tracks the CURRENT disk: a later watcher event for that same
    // disk content must not re-fire the conflict after "Keep mine".
    d.keepMineAfterExternalChange();
    expect(d.hasExternalConflict, isFalse);
    ws.dispose();
  });

  test('Restore adopts disk for a clean tab when auto-reload is ON', () async {
    // Auto-reload ON: a clean tab silently picks up the file's current content
    // (no conflict), matching the live auto-reload watcher path.
    SharedPreferences.setMockInitialValues({'auto_reload': true});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessar');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/y.md')..writeAsStringSync('newer disk');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'stale buffer',
            'dirty': false,
            'mode': 'preview',
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.currentMarkdown(), 'newer disk'); // adopted current file
    expect(d.hasExternalConflict, isFalse);
    expect(d.isDirty, isFalse);
    ws.dispose();
  });

  test('Restore marks a dirty tab clean when disk already matches the buffer',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessclean');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Saved dirty, but another tool wrote the file to exactly the buffer while
    // closed: restore must return a CLEAN tab (no phantom dirty/close prompt).
    final f = File('${tmp.path}/doc.md')..writeAsStringSync('my edits');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'my edits',
            'dirty': true,
            'mode': 'split',
            'synced': 'old disk',
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.currentMarkdown(), 'my edits');
    expect(d.isDirty, isFalse); // clean — disk already has this text
    expect(d.hasExternalConflict, isFalse);
    ws.dispose();
  });

  test('Restore abandons to a pre-opened doc without clobbering the session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {'path': null, 'content': 'saved work', 'dirty': true, 'mode': 'raw'},
        ],
      });
    final saved = store.data;
    final ws = WorkspaceController(prefs, sessionStore: store);
    // A document is already open (an instance-forward / early channel open)
    // before restore runs — restore must bail AND suppress persistence.
    ws.openDocument('a forwarded file', path: '/tmp/fwd.md');
    await ws.restoreSession();
    expect(ws.sessionEnabled, isFalse); // persistence suppressed for this run
    expect(await ws.flushSession(), isTrue); // no-op success
    expect(store.data, saved); // saved session untouched
    ws.dispose();
  });

  test(
      'Update relaunch restores the file-args window without clobbering the '
      'persistent session', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessrelaunch');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // The persistent session from a previous plain launch — note its unsaved
    // buffer, protected by hot exit; it must survive a file-args update.
    final old = File('${tmp.path}/old.md')..writeAsStringSync('# Old on disk');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': old.path,
            'content': '# Old edited (unsaved)',
            'dirty': true,
            'mode': 'raw',
            'synced': '# Old on disk',
          },
        ],
      });
    final protected = store.data;
    final relaunch = _FakeSessionStore();

    // This run was launched by double-clicking current.md: a store, but
    // auto-persist OFF so ordinary editing can't clobber the saved session.
    final current = File('${tmp.path}/current.md')
      ..writeAsStringSync('# Current');
    final ws = WorkspaceController(prefs,
        sessionStore: store, relaunchStore: relaunch, autoPersist: false);
    ws.openDocument('# Current', path: current.path);
    expect(ws.sessionEnabled, isFalse); // no auto-save this run…
    expect(ws.willRestoreOnRelaunch, isTrue); // …but it CAN snapshot for update

    // A normal flush (window close) must not touch the persistent session.
    await ws.flushSession();
    expect(store.data, protected);

    // The update snapshots to the SEPARATE relaunch store; session.json intact.
    expect(await ws.persistSessionForRelaunch(), isTrue);
    expect(store.data, protected); // persistent session STILL protected
    expect(relaunch.data, isNotNull); // one-shot snapshot written
    ws.dispose();

    // The arg-less relaunch (plain launch) CONSUMES the one-shot snapshot,
    // restoring current.md — and clears it so it can't resurface.
    final ws2 = WorkspaceController(prefs,
        sessionStore: store, relaunchStore: relaunch);
    await ws2.restoreSession();
    expect(ws2.documents.length, 1);
    expect(ws2.documents.single.filePath, current.path);
    expect(relaunch.data, isNull); // consumed
    ws2.dispose();

    // A later plain launch (no pending snapshot) restores the protected
    // session — proving the file-args update never clobbered it.
    final ws3 = WorkspaceController(prefs,
        sessionStore: store, relaunchStore: _FakeSessionStore());
    await ws3.restoreSession();
    expect(ws3.documents.single.filePath, old.path);
    expect(ws3.documents.single.currentMarkdown(), '# Old edited (unsaved)');
    expect(ws3.documents.single.isDirty, isTrue);
    ws3.dispose();
  });

  test('A torn-off window (no stores) cannot persist for a relaunch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Torn-off: no session store, no relaunch store, auto-persist off.
    final ws = WorkspaceController(prefs, autoPersist: false);
    expect(ws.willRestoreOnRelaunch, isFalse);
    // Nothing to write to — the caller falls back to its discard prompt.
    expect(await ws.persistSessionForRelaunch(), isFalse);
    ws.dispose();
  });

  test('An abandoned session is not restorable and is never overwritten',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {'path': null, 'content': 'saved work', 'dirty': true, 'mode': 'raw'},
        ],
      });
    final saved = store.data;
    final relaunch = _FakeSessionStore();
    final ws = WorkspaceController(prefs,
        sessionStore: store, relaunchStore: relaunch);
    // A forwarded doc arrived before restore → restore abandons and protects
    // the saved session.
    ws.openDocument('a forwarded file', path: '/tmp/fwd.md');
    await ws.restoreSession();
    // An update started from here must NOT snapshot (it would overwrite the
    // deliberately protected session on a later plain launch)…
    expect(ws.willRestoreOnRelaunch, isFalse);
    expect(await ws.persistSessionForRelaunch(), isFalse);
    expect(store.data, saved); // …the saved session is untouched…
    expect(relaunch.data, isNull); // …and no one-shot snapshot was written.
    ws.dispose();
  });

  test('persistSessionForRelaunch reports a failed one-shot write', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // A file-args launch whose relaunch store can't write (disk full): the
    // snapshot fails, so the update flow aborts rather than relaunch stale.
    final ws = WorkspaceController(prefs,
        sessionStore: _FakeSessionStore(),
        relaunchStore: _ThrowingSessionStore(),
        autoPersist: false);
    ws.openDocument('# X', path: '/tmp/x.md');
    expect(ws.willRestoreOnRelaunch, isTrue); // has a relaunch store…
    expect(await ws.persistSessionForRelaunch(), isFalse); // …but write fails
    ws.dispose();
  });

  test('FileSessionStore round-trips through the real filesystem', () async {
    final dir = Directory.systemTemp.createTempSync('mdfss');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileSessionStore(directory: dir);
    expect(await store.read(), isNull); // nothing yet
    await store.write('{"v":1}');
    expect(await store.read(), '{"v":1}');
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('FileSessionStore read falls back to the temp after a crash mid-rename',
      () async {
    final dir = Directory.systemTemp.createTempSync('mdfss2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileSessionStore(directory: dir);
    // Simulate a crash right after a non-atomic rename removed the destination
    // but before it moved the temp into place: only the .tmp exists, complete.
    File('${dir.path}/session.json.tmp').writeAsStringSync('{"complete":true}');
    expect(await store.read(), '{"complete":true}'); // recovered, not lost
  });

  test('FileSessionStore prefers the main file over a stale temp', () async {
    final dir = Directory.systemTemp.createTempSync('mdfss3');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = FileSessionStore(directory: dir);
    File('${dir.path}/session.json').writeAsStringSync('MAIN');
    File('${dir.path}/session.json.tmp').writeAsStringSync('STALE');
    expect(await store.read(), 'MAIN'); // temp is only a fallback
    // clear() also removes the stale temp so it can't resurrect the session.
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('Malformed session entries are skipped, not fatal', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {'path': 42, 'content': 'bad'}, // non-string path → would throw
          {'path': null, 'content': 'good', 'dirty': true, 'mode': 'raw'},
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    // The malformed entry is skipped; the valid one restores.
    expect(ws.documents.length, 1);
    expect(ws.documents.first.currentMarkdown(), 'good');
    ws.dispose();
  });

  test('A non-list docs value degrades to an empty restore', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // A corrupt/forward-incompatible session where docs isn't a list must not
    // throw — restore leaves the fresh blank document in place.
    final store = _FakeSessionStore()
      ..data = jsonEncode({'version': 1, 'active': 0, 'docs': 'oops'});
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    expect(ws.documents.length, 1);
    expect(ws.documents.first.isPristine, isTrue);
    ws.dispose();
  });

  test('A non-int active index degrades to tab 0, not a launch crash',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // A corrupt/forward-version session where active is a string must not throw
    // (restoreSession is awaited before runApp — a crash here blocks launch).
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 'oops',
        'docs': [
          {'path': null, 'content': 'a', 'dirty': true, 'mode': 'raw'},
          {'path': null, 'content': 'b', 'dirty': true, 'mode': 'raw'},
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    expect(ws.documents.length, 2); // both tabs restored…
    expect(ws.activeIndex, 0); // …and active fell back to tab 0
    ws.dispose();
  });

  test('A dirty tab does NOT conflict if the file already matches the buffer',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final tmp = Directory.systemTemp.createTempSync('mdsessnc');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // While closed, another tool saved the file to exactly the unsaved buffer,
    // so there is nothing to reconcile — no false conflict should resurface.
    final f = File('${tmp.path}/doc.md')..writeAsStringSync('my edits');
    final store = _FakeSessionStore()
      ..data = jsonEncode({
        'version': 1,
        'active': 0,
        'docs': [
          {
            'path': f.path,
            'name': null,
            'content': 'my edits',
            'dirty': true,
            'mode': 'split',
            'synced': 'old disk',
          },
        ],
      });
    final ws = WorkspaceController(prefs, sessionStore: store);
    await ws.restoreSession();
    final d = ws.documents.last;
    expect(d.currentMarkdown(), 'my edits');
    expect(d.hasExternalConflict, isFalse);
    ws.dispose();
  });

  test('flushSession reports a write failure so the caller can warn', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws =
        WorkspaceController(prefs, sessionStore: _ThrowingSessionStore());
    ws.openDocument('unsaved', path: '/tmp/x.md');
    expect(await ws.flushSession(), isFalse);
    ws.dispose();
  });

  test('A blank starter tab is not persisted as real work', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore();
    final ws = WorkspaceController(prefs, sessionStore: store);
    // Only the default pristine Untitled is open.
    await ws.flushSession();
    final snap = jsonDecode(store.data!) as Map<String, dynamic>;
    expect(snap['docs'], isEmpty); // nothing real to restore
    ws.dispose();
  });

  test('A dirty restored tab conflicts if its file changed while closed',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = _FakeSessionStore();
    final tmp = Directory.systemTemp.createTempSync('mdsess3');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final f = File('${tmp.path}/doc.md')..writeAsStringSync('v1 on disk');

    final ws = WorkspaceController(prefs, sessionStore: store);
    ws.openDocument('v1 on disk', path: f.path);
    ws.documents.last.setMode(EditorMode.split);
    ws.documents.last.sourceController.text = 'my unsaved edit';
    await ws.flushSession();
    ws.dispose();

    // The file is changed by another tool while the app is closed.
    f.writeAsStringSync('v2 changed externally');

    final ws2 = WorkspaceController(prefs, sessionStore: store);
    await ws2.restoreSession();
    final d = ws2.documents.last;
    expect(d.currentMarkdown(), 'my unsaved edit'); // buffer preserved
    expect(d.isDirty, isTrue);
    // The external change is surfaced as a conflict, not silently ignored.
    expect(d.hasExternalConflict, isTrue);
    expect(d.pendingExternalContent, 'v2 changed externally');
    ws2.dispose();
  });

  test('Session restore is a no-op with no saved session', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs, sessionStore: _FakeSessionStore());
    await ws.restoreSession();
    // The fresh blank document is left in place.
    expect(ws.documents.length, 1);
    expect(ws.documents.first.isPristine, isTrue);
    ws.dispose();
  });

  testWidgets('A table shows a Copy table chip that copies TSV',
      (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    // A table whose cells exercise the parser: bold header, inline code, a
    // link, a literal underscore, and an HTML entity.
    const md = 'x\n\n'
        '| **Id** | Note |\n'
        '| --- | --- |\n'
        '| order_id | AT&amp;T `x` |\n'
        '| [Bob](https://x.test) | ok |\n';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PreviewView(markdown: md)),
    ));
    await tester.pumpAndSettle();

    final chip = find.text('Copy table');
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();

    final copied = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    // TSV = plain cell values: bold stripped, underscore kept, entity decoded
    // (AT&T not AT&amp;T), inline code as text, link as its label.
    expect(
        (copied.arguments as Map)['text'],
        'Id\tNote\n'
        'order_id\tAT&T x\n'
        'Bob\tok');
    expect(find.text('Copied'), findsOneWidget);
    // Let the confirmation timer elapse so it doesn't outlive the test.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Copy table'), findsOneWidget);
  });

  testWidgets('A table-shaped example inside a code block gets no chip',
      (tester) async {
    const md = 'text\n\n```\n| not | a | table |\n'
        '| --- | --- | --- |\n| x | y | z |\n```\n';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: PreviewView(markdown: md)),
    ));
    await tester.pumpAndSettle();
    // The real parser keeps it as code — no table, no Copy table chip.
    expect(find.text('Copy table'), findsNothing);
  });

  test('Print profiles seed with built-ins', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.length, greaterThanOrEqualTo(2));
    expect(service.profiles.any((p) => p.name == 'Work'), isTrue);
    expect(service.profiles.any((p) => p.name == 'Personal'), isTrue);
  });

  test('New built-in seeds merge into a pre-existing saved profile list',
      () async {
    // A pre-existing install whose saved profiles predate Court Filing, with no
    // seeded-ids marker yet.
    final saved = PrintProfile.encodeList(
        const [PrintProfile.personal, PrintProfile.work]);
    SharedPreferences.setMockInitialValues({'print_profiles': saved});
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.any((p) => p.id == 'court-filing'), isTrue);
    expect(service.profiles.any((p) => p.id == 'work'), isTrue);
  });

  test('A deliberately-deleted built-in seed is not resurrected on reload',
      () async {
    final saved = PrintProfile.encodeList(const [PrintProfile.personal]);
    SharedPreferences.setMockInitialValues({
      'print_profiles': saved,
      // Marker records personal+work as already introduced (work was deleted).
      'seeded_profile_ids': jsonEncode(['personal', 'work']),
    });
    final prefs = await SharedPreferences.getInstance();
    final service = PrintProfileService(prefs);

    expect(service.profiles.any((p) => p.id == 'work'), isFalse);
    // A genuinely new seed still arrives.
    expect(service.profiles.any((p) => p.id == 'court-filing'), isTrue);
  });

  test('Court Filing seed carries the legal formatting defaults', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    expect(court.legalMode, isTrue);
    expect(court.justifyBody, isTrue);
    expect(court.centerHeadings, isTrue);
    expect(court.lineSpacingMultiple, 2.0);
    expect(court.firstLineIndentIn, 0.5);
  });

  test('New legal fields survive a JSON round-trip (and clamp on import)', () {
    const p = PrintProfile(
      id: 'x',
      name: 'X',
      legalMode: true,
      justifyBody: true,
      centerHeadings: true,
      lineSpacingMultiple: 1.5,
      firstLineIndentIn: 0.5,
    );
    final back = PrintProfile.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
    expect(back.legalMode, isTrue);
    expect(back.justifyBody, isTrue);
    expect(back.centerHeadings, isTrue);
    expect(back.lineSpacingMultiple, 1.5);
    expect(back.firstLineIndentIn, 0.5);

    // Out-of-range imports clamp into the editor's slider ranges.
    final clamped = PrintProfile.fromJson({
      'id': 'y',
      'name': 'Y',
      'lineSpacingMultiple': 9.0,
      'firstLineIndentIn': -3.0,
    });
    expect(clamped.lineSpacingMultiple, 2.0);
    expect(clamped.firstLineIndentIn, 0.0);
  });

  test('Inline <span> fill-in lines and labels never leak as literal HTML', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());

    String literal(List<pw.InlineSpan> spans) {
      final sb = StringBuffer();
      void walk(pw.InlineSpan s) {
        if (s is pw.TextSpan) {
          if (s.text != null) sb.write(s.text);
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            walk(c);
          }
        }
      }

      for (final s in spans) {
        walk(s);
      }
      return sb.toString();
    }

    // A signature/date blank: a span with a bottom border and only whitespace.
    final blank = builder.renderInlineText(
      'Name: <span style="display:inline-block; min-width:150px; '
      'border-bottom:1px solid #555;"> </span> Date',
    );
    final blankText = literal(blank);
    expect(blankText.contains('<span'), isFalse);
    expect(blankText.contains('min-width'), isFalse);
    expect(blankText.contains('Name:'), isTrue);
    expect(blankText.contains('Date'), isTrue);
    // The blank line itself is drawn as a widget, not text.
    expect(blank.any((s) => s is pw.WidgetSpan), isTrue);

    // A styled label span keeps its text but drops the markup.
    final label = builder.renderInlineText(
        'A <span style="color:#c00; font-weight:bold;">label</span> here.');
    final labelText = literal(label);
    expect(labelText.contains('<span'), isFalse);
    expect(labelText.contains('label'), isTrue);
    expect(label.every((s) => s is! pw.WidgetSpan), isTrue);

    // Uppercase / mixed-case tags are handled (HTML tags are case-insensitive).
    final upper = builder.renderInlineText('X <SPAN>Y</SPAN> Z');
    final upperText = literal(upper);
    expect(upperText.contains('SPAN'), isFalse);
    expect(upperText, contains('Y'));

    // Nested spans must not leak the outer </span>.
    final nested = builder.renderInlineText(
        'p <span style="color:#c00;">a <span style="font-weight:bold;">b</span> c</span> q');
    final nestedText = literal(nested);
    expect(nestedText.contains('span'), isFalse);
    expect(nestedText.contains('<'), isFalse);
    expect(nestedText, contains('q'));

    // A single unclosed span (truncated export) must not leak either.
    final unclosed =
        builder.renderInlineText('Name: <span style="min-width:150px">');
    final unclosedText = literal(unclosed);
    expect(unclosedText.contains('span'), isFalse);
    expect(unclosedText.contains('min-width'), isFalse);
    expect(unclosedText, contains('Name:'));

    // A blank wrapped in an outer styling span still renders as a blank line.
    final wrappedBlank = builder.renderInlineText(
        '<span style="color:#555;"><span style="min-width:150px; '
        'border-bottom:1px solid;"> </span></span>');
    expect(wrappedBlank.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(wrappedBlank).contains('span'), isFalse);

    // A stray closing tag before a later span must not leak.
    final stray = builder.renderInlineText(
        '</span> <span style="min-width:150px; border-bottom:1px solid;"> '
        '</span>');
    expect(literal(stray).contains('span'), isFalse);
    expect(stray.any((s) => s is pw.WidgetSpan), isTrue);

    // HTML entities in span-adjacent text are decoded (not shown literally).
    final ent =
        builder.renderInlineText('AT&amp;T <span style="color:#333;">x</span>');
    expect(literal(ent), contains('AT&T'));
    expect(literal(ent).contains('&amp;'), isFalse);

    // An explicit zero-width blank collapses (no visible rule).
    final zero = builder
        .renderInlineText('<span style="width:0; border-bottom:1px solid;"> '
            '</span>');
    expect(zero.any((s) => s is pw.WidgetSpan), isFalse);

    // A borderless empty span contributes nothing (no stray space).
    final empty = builder.renderInlineText('X<span id="bookmark"></span>Y');
    expect(literal(empty), 'XY');

    // The bordered (blank) span is the *outer* one; its whitespace is wrapped in
    // a nested span. The fill-in line must still be drawn.
    final outerBlank = builder.renderInlineText(
        '<span style="min-width:150px; border-bottom:1px solid;">'
        '<span>&nbsp;</span></span>');
    expect(outerBlank.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(outerBlank).contains('span'), isFalse);

    // A zero-percent width collapses like an absolute zero.
    final zeroPct = builder.renderInlineText(
        '<span style="width:0%; border-bottom:1px solid;"> </span>');
    expect(zeroPct.any((s) => s is pw.WidgetSpan), isFalse);

    // A whitespace-only styled span is a separator — keep the space.
    final sep = builder
        .renderInlineText('First<span style="color:#555;">&nbsp;</span>Last');
    expect(literal(sep), 'First Last');

    // A colourless border with a transparent currentColor stays invisible.
    final invisible = builder.renderInlineText(
        '<span style="color:transparent; border-bottom:1px solid;"> </span>');
    expect(invisible.any((s) => s is pw.WidgetSpan), isFalse);

    // Transparency inherited from a wrapper span keeps a nested blank invisible.
    final wrapInvisible = builder.renderInlineText(
        '<span style="color:transparent;"><span style="border-bottom:1px '
        'solid; min-width:120px;"> </span></span>');
    expect(wrapInvisible.any((s) => s is pw.WidgetSpan), isFalse);

    // width:50% with a min-width:0 reset must NOT collapse (falls back default).
    final pctReset = builder.renderInlineText(
        '<span style="width:50%; min-width:0; border-bottom:1px solid;"> '
        '</span>');
    expect(pctReset.any((s) => s is pw.WidgetSpan), isTrue);

    // A self-closing bookmark span must not swallow a following fill-in line.
    final selfClose = builder
        .renderInlineText('A<span id="bm"/> <span style="min-width:120px; '
            'border-bottom:1px solid;"> </span>');
    expect(selfClose.any((s) => s is pw.WidgetSpan), isTrue);
    expect(literal(selfClose).contains('span'), isFalse);
    expect(literal(selfClose), contains('A'));

    // A later border-bottom shorthand resets an earlier explicit colour, so the
    // transparent currentColor makes the blank invisible.
    final shorthandReset = builder.renderInlineText(
        '<span style="color:transparent; border-bottom-color:#555; '
        'border-bottom:1px solid;"> </span>');
    expect(shorthandReset.any((s) => s is pw.WidgetSpan), isFalse);

    // Transparent label text is hidden, not printed in the inherited colour.
    final redacted =
        builder.renderInlineText('A<span style="color:transparent;">secret'
            '</span>B');
    expect(literal(redacted).contains('secret'), isFalse);
    expect(literal(redacted), contains('A'));

    // Transparent wrapper hides its plain text too, not just a nested span.
    final wrapHide = builder.renderInlineText(
        '<span style="color:transparent;">secret <span>x</span> tail</span>');
    final wrapText = literal(wrapHide);
    expect(wrapText.contains('secret'), isFalse);
    expect(wrapText.contains('tail'), isFalse);

    // A self-closing bordered span is a fill-in line, not a skipped bookmark.
    final selfBlank = builder.renderInlineText(
        '<span style="min-width:150px; border-bottom:1px solid #555;" />');
    expect(selfBlank.any((s) => s is pw.WidgetSpan), isTrue);

    // A <span> used as a Markdown link label must not leak its markup.
    final linkSpan = builder
        .build('[<span style="color:#c00;">label</span>](https://example.com)');
    String widgetLiteral(pw.InlineSpan s) {
      final sb = StringBuffer();
      if (s is pw.TextSpan) {
        if (s.text != null) sb.write(s.text);
        for (final c in s.children ?? const <pw.InlineSpan>[]) {
          sb.write(widgetLiteral(c));
        }
      }
      return sb.toString();
    }

    // The paragraph is a Padding → RichText; dig out the RichText span text.
    final para = linkSpan.first;
    final rich = para is pw.Padding ? para.child : para;
    if (rich is pw.RichText) {
      final t = widgetLiteral(rich.text);
      expect(t.contains('<span'), isFalse);
      expect(t, contains('label'));
    }

    // A forced colour (white table headers) overrides a styled span's own
    // colour, so header links/labels don't go dark-on-fill.
    final forced = builder.renderInlineText(
        '<span style="color:#111111;">Docs</span>',
        forceColor: PdfColors.white);
    final forcedSpan =
        forced.whereType<pw.TextSpan>().firstWhere((s) => s.text == 'Docs');
    expect(forcedSpan.style?.color, PdfColors.white);

    // An inline-code link label that references a span tag stays literal.
    final codeLink = builder.build('[`<span>x</span>`](https://example.com)');
    final cpara = codeLink.first;
    final crich = cpara is pw.Padding ? cpara.child : cpara;
    if (crich is pw.RichText) {
      expect(widgetLiteral(crich.text), contains('<span>x</span>'));
    }

    // A transparent span inside a link is still hidden (not forced visible).
    final linkHidden = builder.build(
        'A [<span style="color:transparent;">secret</span>](https://example.com) B');
    final lhpara = linkHidden.first;
    final lhrich = lhpara is pw.Padding ? lhpara.child : lhpara;
    if (lhrich is pw.RichText) {
      expect(widgetLiteral(lhrich.text).contains('secret'), isFalse);
    }

    // An unbalanced opening span before a balanced fill-in span must not eat it.
    final truncated = builder.renderInlineText(
        'A <span style="color:#555;">note <span style="min-width:120px; '
        'border-bottom:1px solid;"> </span>');
    expect(truncated.any((s) => s is pw.WidgetSpan), isTrue);

    // A code link label keeps the link underline affordance.
    final codeUnderline = builder.build('[`code`](https://example.com)');
    final cupara = codeUnderline.first;
    final curich = cupara is pw.Padding ? cupara.child : cupara;
    if (curich is pw.RichText) {
      pw.TextSpan? codeSpan;
      void find(pw.InlineSpan s) {
        if (s is pw.TextSpan) {
          if (s.text == 'code') codeSpan = s;
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            find(c);
          }
        }
      }

      find(curich.text);
      expect(codeSpan?.style?.decoration, isNotNull);
    }
  });

  test('Table cells render inline <span> instead of leaking the markup',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    // A form-row table with a fill-in blank in a cell.
    final widgets = builder.build(
      '| Field | Value |\n'
      '|---|---|\n'
      '| Signed | <span style="min-width:150px; border-bottom:1px solid #555;"> '
      '</span> |\n'
      // A cell with inline code that mentions a span tag must keep it literal.
      '| Code | `<span>x</span>` |\n',
    );
    expect(widgets, isNotEmpty);
    // Lays out end-to-end (the cell's WidgetSpan blank would otherwise throw).
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(build: (_) => widgets));
    expect(await doc.save(), isNotEmpty);
  });

  test('PDF builder renders a double-spaced, justified, indented body',
      () async {
    // Exercises the justify + first-line-indent WidgetSpan + centred-heading
    // paths; a layout crash in any of them would fail here.
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final widgets = builder.build(
      '# In re: Example Matter\n\n'
      'This is a body paragraph long enough to wrap onto several lines so '
      'that justification, double spacing and the first-line indent all take '
      'effect during layout. It keeps going to force at least one wrap.\n\n'
      'A second paragraph with **bold** text and a [link](https://example.com).\n\n'
      'Signed: <span style="min-width:180px; border-bottom:1px solid #555;"> '
      '</span>',
    );
    expect(widgets, isNotEmpty);

    final doc = pw.Document();
    doc.addPage(pw.MultiPage(build: (_) => widgets));
    final bytes = await doc.save();
    expect(bytes, isNotEmpty);
  });

  test('A text-align:center <div> renders a centered Text block', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="text-align:center">IN THE CIRCUIT COURT OF BENTON '
            'COUNTY, ARKANSAS<br>DOMESTIC RELATIONS DIVISION</div>');
    final texts = _walk(ws).whereType<pw.Text>();
    expect(texts.any((t) => t.textAlign == pw.TextAlign.center), isTrue);
    // Centered text is stretched to full width so alignment positions it.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isTrue);
    // Lays out without a crash.
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A display:flex; space-between <div> renders a two-column Row',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div><div>PLAINTIFF</div></div>');
    final row = _walk(ws).whereType<pw.Row>().first;
    expect(row.mainAxisAlignment, pw.MainAxisAlignment.spaceBetween);
    expect(row.children.length, 2);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A plain <div> still renders left-aligned and un-stretched (regression)',
      () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('<div>Plain left text</div>');
    final texts = _walk(ws).whereType<pw.Text>().toList();
    expect(texts, isNotEmpty);
    expect(texts.every((t) => t.textAlign == pw.TextAlign.left), isTrue);
    // No full-width stretch box was introduced for an unstyled div.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
  });

  test('display:flex; flex-direction:column stacks (not a row)', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('<div style="display:flex; flex-direction:column">'
        '<div>A</div><div>B</div></div>');
    // A column direction must not become a horizontal Row.
    expect(_walk(ws).whereType<pw.Row>(), isEmpty);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A nested wrapper + aligned grandchild inside a flex row lays out',
      () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    // The 2nd column wraps a centered grandchild — it must shrink-wrap, not
    // take the full-width path (which would overflow the Row and throw).
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div>'
            '<div><div style="text-align:center">v.</div></div></div>');
    // No full-width stretch box leaked into the row context.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('A fill-in blank inside a flex row is bounded (no overflow)', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>Signed:</div>'
            '<div style="border-bottom:1px solid; width:150px"></div></div>');
    // The blank is a bounded finite-width rule (150px → 112.5pt), not a
    // full-width / Expanded rule that would overflow the Row.
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width != null && b.width!.isFinite && b.width! > 0),
        isTrue);
    expect(
        _walk(ws)
            .whereType<pw.SizedBox>()
            .any((b) => b.width == double.infinity),
        isFalse);
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('legalMode paragraphs carry the full spaced block gap', () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    // (The trailing block's own gap is trimmed at the document end, so this
    // doc ends with a closing paragraph to keep four inter-block gaps.)
    final ws = builder.build('First paragraph of the motion.\n\n'
        'Second paragraph of the motion.\n\n'
        '- first ground\n- second ground\n\n'
        'Respectfully submitted.');
    // Uniform rhythm: the inter-block gap == in-paragraph leading, so the
    // baseline-to-baseline distance across a paragraph break equals the
    // double-spaced line height (2.5 + 12 × (multiple − 1) = 14.5 at 2.0,
    // derived from the 12pt legal body). Flowing blocks carry the gap as a
    // sibling SizedBox (a padding wrapper would waste the gap's height at
    // every page split).
    final expected = 2.5 + 12.0 * (court.lineSpacingMultiple - 1.0);
    final gaps = ws
        .whereType<pw.SizedBox>()
        .where((s) => s.height == expected && s.width == null);
    expect(gaps.length, 4,
        reason: 'both paragraphs and both list items carry the spaced gap');
    final bottoms = _walk(ws)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom)
        .toList();
    expect(bottoms.contains(8.0), isFalse,
        reason: 'no legal block keeps the single-spaced 8pt gap');
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);
  });

  test('Non-legal paragraphs keep the historical 8pt gap (regression)', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build('First paragraph.\n\nSecond paragraph.');
    final bottoms = _walk(ws)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(bottoms.where((b) => b == 8.0).length, 2);
  });

  test('legalMode body text and plain <div>s render at 12pt', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final legal = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final plain = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());

    // Every text-span font size reachable from the built widgets.
    Iterable<double> spanSizes(List<pw.Widget> ws) sync* {
      Iterable<double> walk(pw.InlineSpan s) sync* {
        if (s is pw.TextSpan) {
          final size = s.style?.fontSize;
          if (size != null) yield size;
          for (final c in s.children ?? const <pw.InlineSpan>[]) {
            yield* walk(c);
          }
        }
      }

      for (final r in _walk(ws).whereType<pw.RichText>()) {
        yield* walk(r.text);
      }
    }

    // Body paragraphs: 12pt in legal mode, historical 11pt otherwise.
    final legalBody =
        spanSizes(legal.build('Comes now the Defendant.')).toList();
    expect(legalBody, isNotEmpty);
    expect(legalBody.every((s) => s == 12.0), isTrue);
    final plainBody = spanSizes(plain.build('A plain paragraph.')).toList();
    expect(plainBody, isNotEmpty);
    expect(plainBody.every((s) => s == 11.0), isTrue);

    // A <div> with no font-size matches the body in legal mode (12pt), keeps
    // the historical 10pt otherwise; an explicit font-size still wins.
    final legalDiv = spanSizes(legal.build('<div>MEGHAN MAIN</div>')).toList();
    expect(legalDiv, isNotEmpty);
    expect(legalDiv.every((s) => s == 12.0), isTrue);
    final plainDiv = spanSizes(plain.build('<div>MEGHAN MAIN</div>')).toList();
    expect(plainDiv, isNotEmpty);
    expect(plainDiv.every((s) => s == 10.0), isTrue);
    final explicit =
        spanSizes(legal.build('<div style="font-size:14pt">Exhibit A</div>'))
            .toList();
    expect(explicit, isNotEmpty);
    expect(explicit.every((s) => s == 14.0), isTrue);
  });

  test('legalMode paragraphs and list items flow across page boundaries',
      () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    const sentence =
        'The hearing in this matter is currently set for a date on which the '
        'Defendant is unavailable for reasons entirely beyond his control. ';

    Future<int> pageCount(List<pw.Widget> ws) async {
      final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
      final bytes = await doc.save();
      return RegExp(r'/Type\s*/Page\b')
          .allMatches(String.fromCharCodes(bytes))
          .length;
    }

    // A single paragraph taller than a page must split across the boundary
    // (as an atomic block this used to throw "Widget won't fit").
    final long = builder.build(sentence * 60);
    expect(
        _walk(long)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isTrue);
    final longPages = await pageCount(long);
    expect(longPages, greaterThanOrEqualTo(2));

    // A single numbered item taller than a page flows the same way, with its
    // marker inline.
    final item = builder.build('1. ${sentence * 60}');
    expect(_literalText(_walk(item)).contains('1.'), isTrue);
    final itemPages = await pageCount(item);
    expect(itemPages, greaterThanOrEqualTo(2));

    // Filled pages: an intro plus four ~⅔-page paragraphs (~2.7 pages of
    // text) fits in three flowing pages; placed atomically each paragraph
    // would demand a fresh page (four total, each ending in a blank band).
    final chunk = sentence * 10;
    final filled = await pageCount(
        builder.build('Intro.\n\n$chunk\n\n$chunk\n\n$chunk\n\n$chunk'));
    expect(filled, lessThanOrEqualTo(3));

    // The final block's gap is trimmed: the document never ends in a bare
    // spacer that could spill onto a blank trailing page.
    bool bareGap(pw.Widget w) =>
        w is pw.SizedBox && w.width == null && w.child == null;
    expect(bareGap(builder.build('Only paragraph.').last), isFalse);

    // A gap is also trimmed directly before a forced page break…
    final broken =
        builder.build('A\n\n<div style="page-break-before:always"></div>\n\nB');
    final breakAt = broken.indexWhere((w) => w is pw.NewPage);
    expect(breakAt, greaterThan(0));
    expect(bareGap(broken[breakAt - 1]), isFalse);

    // …and prose sharing a raw block with the break directive still flows
    // (it must be able to split across pages like any legal paragraph).
    final sharedBlock = builder
        .build('<div style="page-break-before:always"></div>\n${sentence * 3}');
    expect(sharedBlock.whereType<pw.NewPage>().length, 1);
    expect(
        _walk(sharedBlock)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isTrue);
  });

  test('Captions, signature divs and headings stay atomic in legal mode', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final ws = builder
        .build('<div style="display:flex; justify-content:space-between">'
            '<div>MEGHAN MAIN</div><div>PLAINTIFF</div></div>\n\n'
            '<div style="width:40%; border-bottom:1px solid #000"></div>\n\n'
            '#### <u>MOTION FOR CONTINUANCE</u>');
    // Nothing in these blocks is page-spanning text, and the caption is
    // still a Row.
    expect(
        _walk(ws)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isFalse);
    expect(_walk(ws).whereType<pw.Row>().isNotEmpty, isTrue);
  });

  test('Non-legal documents never emit page-spanning text (regression)', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws =
        builder.build('A paragraph.\n\nAnother paragraph.\n\n1. one\n2. two');
    expect(
        _walk(ws)
            .whereType<pw.RichText>()
            .any((r) => r.overflow == pw.TextOverflow.span),
        isFalse);
    // Lists keep their single-widget Column structure.
    expect(_walk(ws).whereType<pw.Column>().isNotEmpty, isTrue);
  });

  test('Page-break divs and hrs emit a top-level pw.NewPage', () async {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());

    final ws = builder.build('Body of the motion.\n\n'
        '<div style="page-break-before:always"></div>\n\n'
        '#### <u>CERTIFICATE OF SERVICE</u>\n\nI hereby certify…');
    expect(ws.whereType<pw.NewPage>().length, 1,
        reason: 'a bare page-break div becomes a NewPage');
    // The break contributes no visible content of its own.
    final doc = pw.Document()..addPage(pw.MultiPage(build: (_) => ws));
    expect(await doc.save(), isNotEmpty);

    // <hr> with the directive, and the CSS-3 fragmentation spelling.
    expect(
        builder
            .build('A\n\n<hr style="page-break-after:always">\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);
    expect(
        builder
            .build('A\n\n<div style="break-before:page"></div>\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);

    // Adjacent HTML blocks with no blank line: package:markdown keeps them in
    // one text node — the break must still be found and the caption rendered.
    final adjacent = builder.build('<div style="page-break-before:always">'
        '</div>\n<div style="text-align:center">CERTIFICATE OF SERVICE</div>');
    expect(adjacent.whereType<pw.NewPage>().length, 1);
    expect(
        _walk(adjacent).whereType<pw.Text>().any((t) =>
            ((t.text as pw.TextSpan).text ?? '').contains('CERTIFICATE')),
        isTrue);

    // A visible element carrying the directive breaks AND still renders: a
    // signature line with page-break-before starts a page, then draws.
    final withLine = builder.build('<div style="page-break-before:always; '
        'border-bottom:1px solid; width:150px"></div>');
    expect(withLine.whereType<pw.NewPage>().length, 1);
    expect(_walk(withLine).whereType<pw.Container>().isNotEmpty, isTrue,
        reason: 'the signature rule survives the break');
    expect(withLine.first, isA<pw.NewPage>(),
        reason: '…-before breaks before the element renders');

    // A CSS priority suffix is accepted.
    expect(
        builder
            .build('A\n\n<div style="page-break-before: always !important">'
                '</div>\n\nB')
            .whereType<pw.NewPage>()
            .length,
        1);

    // A break div nested inside a wrapper is NOT split out of it: the wrapper
    // renders intact (no leaked </div>), and no page break is emitted.
    final nestedBreak = builder.build('<div style="text-align:center">'
        '<div style="page-break-before:always"></div>CERTIFICATE</div>');
    expect(nestedBreak.whereType<pw.NewPage>(), isEmpty);
    final nestedText = _literalText(_walk(nestedBreak));
    expect(nestedText.contains('</div'), isFalse);
    expect(nestedText.contains('CERTIFICATE'), isTrue);

    // A plain thematic break (---) still renders a divider, not a page break.
    expect(builder.build('A\n\n---\n\nB').whereType<pw.NewPage>(), isEmpty);
    // A bare div without the directive is unchanged too.
    expect(
        builder
            .build('<div style="height:12px"></div>')
            .whereType<pw.NewPage>(),
        isEmpty);
  });

  test('A literal <br> in a heading renders as a line break, not text', () {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final ws = builder.build(
        '# IN THE CIRCUIT COURT OF BENTON COUNTY, ARKANSAS<br>DOMESTIC RELATIONS DIVISION');

    String literal(pw.InlineSpan s) {
      final sb = StringBuffer();
      void walk(pw.InlineSpan x) {
        if (x is pw.TextSpan) {
          if (x.text != null) sb.write(x.text);
          for (final c in x.children ?? const <pw.InlineSpan>[]) {
            walk(c);
          }
        }
      }

      walk(s);
      return sb.toString();
    }

    final headingText =
        _walk(ws).whereType<pw.RichText>().map((r) => literal(r.text)).join();
    expect(headingText.contains('<br'), isFalse);
    expect(headingText.contains('\n'), isTrue);

    // Inside a styled span the <br> survives as a line break too (it used to
    // be flattened to a space).
    final label = builder
        .renderInlineText(
            '<span style="font-weight:bold">Line 1<br>Line 2</span>')
        .map(literal)
        .join();
    expect(label.contains('<br'), isFalse);
    expect(label.contains('Line 1\nLine 2'), isTrue);
  });

  test('A long code block paginates instead of overflowing the page', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final code =
        '```\n${List.generate(90, (i) => 'line $i of code').join('\n')}\n```';
    // Before the fix this threw "Widget won't fit into the page…".
    expect(await _renderA4(builder.build(code)), isNotEmpty);
  });

  test('A long multi-paragraph blockquote paginates', () async {
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final quote =
        List.generate(60, (i) => '> Paragraph $i of the quoted passage.')
            .join('\n>\n');
    expect(await _renderA4(builder.build(quote)), isNotEmpty);
  });

  test('A tall image is capped to one page (no overflow)', () async {
    final tmp = Directory.systemTemp.createTempSync('mdimg');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final tall = img.Image(width: 400, height: 3000);
    img.fill(tall, color: img.ColorRgb8(120, 120, 200));
    File('${tmp.path}/tall.png')
        .writeAsBytesSync(Uint8List.fromList(img.encodePng(tall)));

    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal,
        fonts: _standardFonts(),
        baseDir: tmp.path,
        maxImageHeight: 600);
    final ws = builder.build('before\n\n![tall](tall.png)\n\nafter');
    // Without the cap the 3000px image exceeds a page and MultiPage throws.
    expect(await _renderA4(ws), isNotEmpty);

    // The cap must never UPSCALE: capped images render with scaleDown so a
    // small inline image keeps its intrinsic size instead of filling the
    // bounded box.
    bool usesScaleDown(pw.Widget w) =>
        w is pw.Padding &&
        w.child is pw.ConstrainedBox &&
        ((w.child as pw.ConstrainedBox).child as pw.Image).fit ==
            pw.BoxFit.scaleDown;
    expect(_walk(ws).any(usesScaleDown), isTrue);
  });

  test('data-URI, pre-fetched remote, and file:// images all render', () async {
    final tiny = img.Image(width: 4, height: 4);
    img.fill(tiny, color: img.ColorRgb8(200, 60, 60));
    final png = Uint8List.fromList(img.encodePng(tiny));
    final dataUri = 'data:image/png;base64,${base64Encode(png)}';
    const remoteUrl = 'https://example.com/pic.png';
    final tmp = Directory.systemTemp.createTempSync('mdimg2');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final onDisk = File('${tmp.path}/pic.png')..writeAsBytesSync(png);
    final fileUri = Uri.file(onDisk.path).toString();

    // Percent-encoded (non-base64) data URI: binary octets must survive
    // decoding. Every byte is escaped — a markdown link destination ends at
    // an unescaped ')', so an embedded data URI must be fully encoded.
    final percentUri = 'data:image/png,'
        '${png.map((b) => '%${b.toRadixString(16).padLeft(2, '0')}').join()}';
    // URI schemes are case-insensitive; uppercase variants must still work.
    final upperFileUri = fileUri.replaceFirst('file://', 'FILE://');
    const upperUrl = 'HTTPS://example.com/pic2.png';

    // Sources are discovered from the markdown so the caller knows what to
    // pre-fetch; data/file/local sources need no fetching, and cleartext
    // http is never fetched (mobile platforms block it — it degrades to the
    // placeholder everywhere for consistency).
    final mdText = '![a]($dataUri)\n\n![b]($remoteUrl)\n\n![c]($fileUri)\n\n'
        '![d]($percentUri)\n\n![e]($upperFileUri)\n\n![f]($upperUrl)\n\n'
        '![g](http://example.com/insecure.png)';
    expect(
        MarkdownPdfBuilder.remoteImageSources(mdText), {remoteUrl, upperUrl});

    // Discovery mirrors the renderer: images in positions the PDF drops
    // (linked badges, headings, list items) are never fetched; blockquoted
    // paragraph images and table-cell images render, so they are.
    expect(
        MarkdownPdfBuilder.remoteImageSources(
            '[![badge](https://x.test/b.png)](https://x.test)\n\n'
            '# ![h](https://x.test/h.png)\n\n'
            '- ![li](https://x.test/li.png)\n\n'
            '> ![q](https://x.test/q.png)\n\n'
            '| shot |\n| --- |\n| ![t](https://x.test/t.png) |'),
        {'https://x.test/q.png', 'https://x.test/t.png'});

    final builder = MarkdownPdfBuilder(
      profile: PrintProfile.personal,
      fonts: _standardFonts(),
      remoteImages: {remoteUrl: png, upperUrl: png},
    );
    final ws = builder.build(mdText);
    expect(_walk(ws).whereType<pw.Image>().length, 6);
    expect(await _renderA4(ws), isNotEmpty);

    // A remote image that was NOT pre-fetched (offline / failed download)
    // degrades to the textual placeholder instead of throwing.
    final offline = MarkdownPdfBuilder(
        profile: PrintProfile.personal, fonts: _standardFonts());
    final missing = offline.build('![b]($remoteUrl)');
    expect(_walk(missing).whereType<pw.Image>(), isEmpty);
    expect(await _renderA4(missing), isNotEmpty);
  });

  test('Images inside table cells render (screenshot-table pattern)', () async {
    final tmp = Directory.systemTemp.createTempSync('mdimg3');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final shot = img.Image(width: 320, height: 200);
    img.fill(shot, color: img.ColorRgb8(90, 120, 200));
    File('${tmp.path}/shot.png')
        .writeAsBytesSync(Uint8List.fromList(img.encodePng(shot)));

    // The user-reported shape: a two-column table whose second column is a
    // relative-path screenshot per row.
    final builder = MarkdownPdfBuilder(
        profile: PrintProfile.personal,
        fonts: _standardFonts(),
        baseDir: tmp.path,
        maxImageHeight: 600);
    final ws = builder.build('| View | Preview |\n| --- | --- |\n'
        '| Workspace | ![workspace](./shot.png) |\n'
        '| Lobby | ![lobby](shot.png) |');
    expect(_walk(ws).whereType<pw.Image>().length, 2);
    expect(await _renderA4(ws), isNotEmpty);

    // Cell text still renders alongside, and a missing image degrades to
    // the placeholder without breaking the table.
    final broken = builder.build('| a |\n| --- |\n| ![x](gone.png) hi |');
    expect(_walk(broken).whereType<pw.Image>(), isEmpty);
    expect(await _renderA4(broken), isNotEmpty);
  });

  test('legalMode keeps one gap for blockquotes and nested lists', () {
    final court = PrintProfile.seeds.firstWhere((p) => p.id == 'court-filing');
    final builder = MarkdownPdfBuilder(profile: court, fonts: _standardFonts());
    final gap = 2.5 + 12.0 * (court.lineSpacingMultiple - 1.0);

    // The quote's outer bottom padding is the single gap to the next block;
    // the paragraph inside must not add a second one (a blank band in the
    // box). (The quote is a Padding around a Column of per-child decorated
    // containers so tall quotes can paginate.)
    final quote = builder.build('> quoted authority\n\nnext paragraph').first
        as pw.Padding;
    final innerBottoms = _allWidgets(quote.child!)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(innerBottoms.any((b) => b == gap), isFalse,
        reason: 'no double gap inside the quote');
    expect((quote.padding as pw.EdgeInsets).bottom, gap);

    // Nested list: the item with children keeps the atomic layout (parent row
    // + child item carry one padding gap each); the plain 'next' item flows
    // and carries its gap as a sibling SizedBox. (A trailing paragraph keeps
    // that gap from being trimmed as the document tail.)
    final list = builder.build('- parent\n  - child\n- next\n\ntail');
    final bottoms = _walk(list)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom)
        .where((b) => b == gap);
    expect(bottoms.length, 2);
    expect(
        list
            .whereType<pw.SizedBox>()
            .where((s) => s.height == gap && s.width == null)
            .length,
        1);

    // A quote that *ends in a list* sheds the last item's gap too (the trim
    // descends through the list's zero-gap wrapper).
    final listQuote =
        builder.build('> - cited point\n\nnext paragraph').first as pw.Padding;
    final listQuoteBottoms = _allWidgets(listQuote.child!)
        .whereType<pw.Padding>()
        .map((p) => (p.padding as pw.EdgeInsets).bottom);
    expect(listQuoteBottoms.any((b) => b == gap), isFalse,
        reason: 'no gap band inside a quote ending in a list');
  });

  test('Visiting Edit mode without editing preserves the exact source', () {
    // Regression: AppFlowy's Markdown round-trip drops blank lines and rewrites
    // markers, so a no-op Edit → back visit used to reformat untouched text.
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    const source =
        '# Title\n\n* one\n* two\n\nSome __bold__ and *italic* text.\n';
    doc.loadMarkdown(source);

    doc.setMode(EditorMode.wysiwyg); // enter the block editor…
    doc.setMode(EditorMode.preview); // …and leave without editing

    expect(doc.currentMarkdown(), source);
  });

  test('Reloading in Edit mode does not reformat the untouched buffer',
      () async {
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    doc.loadMarkdown('# Title\n\n* one\n* two\n');
    doc.setMode(EditorMode.wysiwyg);

    // Make a genuine WYSIWYG edit so the "edited" flag is set.
    final node = doc.editorState.getNodeAtPath([0])!;
    await doc.editorState
        .apply(doc.editorState.transaction..insertText(node, 0, 'X'));
    await Future<void>.delayed(Duration.zero);
    expect(doc.isDirty, isTrue); // precondition: the edit registered

    // An external reload arrives while still in Edit mode.
    const reloaded = '# Reloaded\n\n* a\n* b\n\nPlain __text__.\n';
    doc.loadMarkdown(reloaded);

    // Leaving Edit must not round-trip the freshly-loaded, untouched buffer.
    doc.setMode(EditorMode.preview);
    expect(doc.currentMarkdown(), reloaded);
  });

  test('Selection-only changes in the source do not mark the doc dirty', () {
    // Find & replace reveals a match by selecting it; navigating matches must
    // not create unsaved-changes state on a clean document.
    final doc = DocumentController(isAutoReloadEnabled: () => false);
    addTearDown(doc.dispose);
    doc.loadMarkdown('hello world hello');
    doc.setMode(EditorMode.raw);
    expect(doc.isDirty, isFalse);

    // Move/select the caret only — no text change.
    doc.sourceController.selection =
        const TextSelection(baseOffset: 0, extentOffset: 5);
    expect(doc.isDirty, isFalse);

    // A genuine text edit still marks it dirty.
    doc.sourceController.text = 'hello world goodbye';
    expect(doc.isDirty, isTrue);
  });

  test('Workspace starts with one tab and manages tabs', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);

    expect(ws.documents.length, 1);

    // Opening into a pristine untitled tab replaces it rather than stacking.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 1);
    expect(ws.activeDocument?.filePath, '/tmp/a.md');

    // A second distinct file adds a tab.
    ws.openDocument('# Second', path: '/tmp/b.md');
    expect(ws.documents.length, 2);
    expect(ws.activeIndex, 1);

    // Re-opening an already-open file just focuses it.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 2);
    expect(ws.activeIndex, 0);

    // Closing always leaves at least one tab.
    ws.closeAt(0);
    ws.closeAt(0);
    expect(ws.documents.length, 1);
  });

  test('Reorder inserts before the target and supports the end', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    ws.openDocument('a', path: '/a.md');
    ws.openDocument('b', path: '/b.md');
    ws.openDocument('c', path: '/c.md');
    expect(ws.documents.map((d) => d.filePath), ['/a.md', '/b.md', '/c.md']);

    ws.reorder(0, 2); // move A before C
    expect(ws.documents.map((d) => d.filePath), ['/b.md', '/a.md', '/c.md']);

    ws.reorder(0, 3); // move B to the end
    expect(ws.documents.map((d) => d.filePath), ['/a.md', '/c.md', '/b.md']);
  });

  test('Print preview opens as a tab and refreshes in place', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    ws.openDocument('# Hello', path: '/tmp/a.md');

    ws.openPrintPreview(markdown: '# Hello', title: 'a', docPath: '/tmp/a.md');
    expect(ws.tabs.length, 2);
    expect(ws.activeTab, isA<PrintPreviewTab>());
    // Previews are not documents: no dirty state, no save, no watcher.
    expect(ws.documents.length, 1);
    expect(ws.activeDocument, isNull);

    // Printing the same file again refreshes the existing preview in place.
    ws.openPrintPreview(
        markdown: '# Hello v2', title: 'a', docPath: '/tmp/a.md');
    expect(ws.tabs.length, 2);
    final preview = ws.activeTab as PrintPreviewTab;
    expect(preview.markdown, '# Hello v2');
    expect(preview.epoch, 1);

    // A different document gets its own preview tab.
    ws.openPrintPreview(markdown: '# B', title: 'b', docPath: '/tmp/b.md');
    expect(ws.tabs.length, 3);

    // Closing a preview never touches the document tabs.
    ws.closeAt(ws.activeIndex);
    expect(ws.tabs.length, 2);
    expect(ws.documents.length, 1);
  });

  test('Pathless documents with the same title get their own previews',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    // Two unsaved documents — both are titled "Untitled".
    final docA = ws.activeDocument!;
    ws.newDocument();
    final docB = ws.activeDocument!;

    ws.openPrintPreview(
        markdown: 'A', title: docA.title, docPath: null, sourceKey: docA);
    ws.openPrintPreview(
        markdown: 'B', title: docB.title, docPath: null, sourceKey: docB);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 2);

    // Re-printing doc A refreshes A's preview, not B's.
    ws.openPrintPreview(
        markdown: 'A v2', title: docA.title, docPath: null, sourceKey: docA);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 2);
    expect((ws.activeTab as PrintPreviewTab).markdown, 'A v2');

    // Closing doc A orphans its preview: printing a fresh pathless document
    // opens a new tab instead of hijacking the orphan.
    ws.closeAt(ws.tabs.indexWhere((t) => t is DocumentTab && t.doc == docA));
    ws.newDocument();
    final docC = ws.activeDocument!;
    ws.openPrintPreview(
        markdown: 'C', title: docC.title, docPath: null, sourceKey: docC);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 3);
  });

  test('A preview follows its document through Save As', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    final doc = ws.activeDocument!;

    // Printed while unsaved: preview is matched by document identity.
    ws.openPrintPreview(
        markdown: 'draft', title: doc.title, docPath: null, sourceKey: doc);
    expect(ws.tabs.whereType<PrintPreviewTab>().length, 1);

    // After Save As, printing again refreshes the same preview (no
    // duplicate) and the preview adopts the new path.
    ws.openPrintPreview(
        markdown: 'saved', title: 'a', docPath: '/tmp/a.md', sourceKey: doc);
    final previews = ws.tabs.whereType<PrintPreviewTab>().toList();
    expect(previews.length, 1);
    expect(previews.single.docPath, '/tmp/a.md');
    expect(previews.single.markdown, 'saved');
    expect(previews.single.epoch, 1);
  });

  test('A sole pristine Untitled is replaced even with previews open',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);
    final untitled = ws.activeDocument!;
    ws.openPrintPreview(
        markdown: '',
        title: untitled.title,
        docPath: null,
        sourceKey: untitled);
    expect(ws.tabs.length, 2);

    // Opening a real file replaces the pristine Untitled document rather
    // than stacking a third tab next to it.
    ws.openDocument('# Hello', path: '/tmp/a.md');
    expect(ws.documents.length, 1);
    expect(ws.documents.single.filePath, '/tmp/a.md');
    expect(ws.tabs.length, 2);
    expect(ws.activeDocument?.filePath, '/tmp/a.md');
  });

  test('Auto-reload defaults on and persists when toggled', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final ws = WorkspaceController(prefs);

    expect(ws.autoReload, isTrue);
    await ws.setAutoReload(false);
    expect(ws.autoReload, isFalse);
    expect(prefs.getBool('auto_reload'), isFalse);

    final reloaded = WorkspaceController(prefs);
    expect(reloaded.autoReload, isFalse);
  });
}

/// In-memory [SessionStore] for session-restore tests (no filesystem).
class _FakeSessionStore implements SessionStore {
  String? data;

  @override
  Future<String?> read() async => data;

  @override
  Future<void> write(String d) async => data = d;

  @override
  Future<void> clear() async => data = null;
}

/// A [SessionStore] whose writes always fail (disk full / unwritable), used to
/// verify the flush-failure fallback.
class _ThrowingSessionStore implements SessionStore {
  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String d) async => throw const FileSystemException('full');

  @override
  Future<void> clear() async {}
}
