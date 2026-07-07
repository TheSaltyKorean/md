import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../models/print_profile.dart';
import '../services/print_profile_service.dart';
import '../services/print_service.dart';
import '../state/zoom_controller.dart';
import 'print_profile_editor.dart';

/// Print / PDF-export experience, hosted in its own workspace tab (not a modal
/// dialog): choose a branding profile, preview the rendered document, then
/// print or share. Profiles can be created, edited, set as default, and
/// associated with the current document. The Markdown shown is a snapshot —
/// printing the document again refreshes the tab in place.
class PrintPreviewView extends StatefulWidget {
  const PrintPreviewView({
    super.key,
    required this.markdown,
    required this.title,
    required this.docPath,
    this.refreshEpoch = 0,
  });

  final String markdown;
  final String title;
  final String? docPath;

  /// Bumped by the workspace when the same preview tab is refreshed with a
  /// new snapshot. The state reacts by re-rendering the PDF — without being
  /// recreated, so the user's profile / page-format selections survive.
  final int refreshEpoch;

  @override
  State<PrintPreviewView> createState() => _PrintPreviewViewState();
}

class _PrintPreviewViewState extends State<PrintPreviewView> {
  final _service = PrintService();
  // Anchors the iPad share popover to the Share button.
  final GlobalKey _shareButtonKey = GlobalKey();
  late String _selectedId;
  int _previewEpoch = 0;

  /// The page format currently shown in the preview (updated as the user
  /// changes size/orientation). "Save as PDF" exports at this format.
  PdfPageFormat _previewFormat = PdfPageFormat.a4;

  @override
  void initState() {
    super.initState();
    final profiles = context.read<PrintProfileService>();
    _selectedId = profiles.forDocument(widget.docPath).id;
  }

  @override
  void didUpdateWidget(PrintPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A refreshed snapshot (print pressed again): re-render the PDF but keep
    // the user's in-preview selections (profile, page size/orientation).
    if (oldWidget.refreshEpoch != widget.refreshEpoch) {
      setState(() => _previewEpoch++);
    }
    // The document's path changed (unsaved → Save As, or Save As from an
    // existing file): carry the remembered profile to the new path — but only
    // when there is a real choice to carry (the user picked one in this
    // preview, or the old path already had a binding). An untouched preview
    // that merely shows the default must NOT pin that default to the file,
    // or the document would stop following future default changes.
    if (oldWidget.docPath != widget.docPath && widget.docPath != null) {
      final service = context.read<PrintProfileService>();
      final hadOldBinding = oldWidget.docPath != null &&
          service.assignedId(oldWidget.docPath) != null;
      if (_userChose || hadOldBinding) {
        service.assignToDocument(widget.docPath!, _selectedId);
      }
    }
  }

  /// True once the user actively picked a profile in this preview (dropdown,
  /// New, or Import) — as opposed to the preview merely showing the
  /// default/inherited profile.
  bool _userChose = false;

  /// Pin ON records the current profile for the file; pin OFF clears the
  /// binding — and also drops the in-session choice, so a later Save As
  /// cannot resurrect an association the user explicitly removed.
  void _togglePin(bool assigned) {
    final path = widget.docPath;
    if (path == null) return;
    _userChose = !assigned;
    context
        .read<PrintProfileService>()
        .assignToDocument(path, assigned ? null : _selectedId);
  }

  /// Select a profile for this preview — and remember it for the document.
  /// Choosing a profile *is* the association (no separate pin step; the pin
  /// icon shows the link and taps clear it), so a work document keeps its
  /// work branding the next time it is printed. Pathless (unsaved) documents
  /// have nothing durable to key on, so the selection sticks once the file
  /// is saved and printed again (see [didUpdateWidget]).
  void _select(String id) {
    _userChose = true;
    setState(() {
      _selectedId = id;
      _previewEpoch++;
    });
    final path = widget.docPath;
    if (path != null) {
      context.read<PrintProfileService>().assignToDocument(path, id);
    }
  }

  Future<void> _editProfile(PrintProfile profile, {required bool isNew}) async {
    final result = await Navigator.of(context).push<PrintProfile>(
      MaterialPageRoute(builder: (_) => PrintProfileEditor(profile: profile)),
    );
    if (result == null || !mounted) return;
    await context.read<PrintProfileService>().upsert(result);
    if (!mounted) return;
    if (isNew || result.id != _selectedId) {
      // A newly created profile is a choice like a dropdown pick — route it
      // through the selection path so the document remembers it.
      _select(result.id);
    } else {
      // Editing the already-shown profile is not a choice: an unassigned
      // document merely displaying the default must not become pinned to it.
      setState(() => _previewEpoch++);
    }
  }

  String _newId() =>
      'profile_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Future<void> _importProfile() async {
    final messenger = ScaffoldMessenger.of(context);
    final service = context.read<PrintProfileService>();
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import print profile (.json)',
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    PrintProfile profile;
    try {
      final file = result.files.single;
      final text = file.bytes != null
          ? utf8.decode(file.bytes!, allowMalformed: true)
          : await File(file.path!).readAsString();
      final map = jsonDecode(text);
      if (map is! Map<String, dynamic> ||
          map['id'] is! String ||
          map['name'] is! String) {
        throw const FormatException('missing required fields');
      }
      // fromJson clamps/validates layout values (margin, colours, enums).
      profile = PrintProfile.fromJson(map);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Import failed: not a valid profile JSON')));
      return;
    }

    // A logo path from another machine won't resolve here — drop it.
    var logoCleared = false;
    if (profile.logoPath != null && !File(profile.logoPath!).existsSync()) {
      profile = profile.copyWith(logoPath: null);
      logoCleared = true;
    }

    if (!mounted) return;
    // Confirm before overwriting an existing profile with the same id.
    if (service.profiles.any((p) => p.id == profile.id)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Replace profile?'),
          content:
              Text('A profile "${profile.name}" already exists. Replace it?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Replace')),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }

    await service.upsert(profile);
    if (!mounted) return;
    // Route through the selection path so an imported profile is also
    // remembered for the document, exactly like a dropdown choice.
    _select(profile.id);
    messenger.showSnackBar(SnackBar(
        content: Text(logoCleared
            ? 'Imported "${profile.name}" (logo not found here — cleared)'
            : 'Imported "${profile.name}"')));
  }

  Future<void> _exportProfile(PrintProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    final json = const JsonEncoder.withIndent('  ').convert(profile.toJson());
    final safe = profile.name.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    final bytes = Uint8List.fromList(utf8.encode(json));
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    try {
      // On desktop, saveFile only returns a chosen path (it does not reliably
      // write the bytes — e.g. on Linux), so we write the file ourselves. On
      // mobile/web, saveFile writes the passed bytes and File access to the
      // returned URI may not work, so we rely on it there.
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Export print profile',
        fileName: '$safe.print-profile.json',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: isDesktop ? null : bytes,
      );
      if (path == null) return; // user cancelled
      if (isDesktop) await File(path).writeAsString(json);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
      return;
    }
    if (mounted) {
      messenger
          .showSnackBar(SnackBar(content: Text('Exported "${profile.name}"')));
    }
  }

  String? get _baseDir =>
      widget.docPath != null ? p.dirname(widget.docPath!) : null;

  /// Open the OS print dialog for the rendered document. Start from the page
  /// size/orientation the user is previewing (the print dialog can still change
  /// it, in which case onLayout rebuilds at the chosen format).
  Future<void> _print(PrintProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Printing.layoutPdf(
        name: widget.title,
        format: _previewFormat,
        onLayout: (format) => _service.generate(
          markdown: widget.markdown,
          profile: profile,
          title: widget.title,
          format: format,
          baseDir: _baseDir,
        ),
      );
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Print failed: $e')));
      }
    }
  }

  /// Share/export the document as a PDF via the platform share sheet.
  Future<void> _share(PrintProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    final safe = widget.title.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    // On iPad the share sheet is a popover anchored to these bounds; without
    // them it falls back to a top-left rect. Anchor it to the Share button.
    final box =
        _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final bounds =
        box != null ? box.localToGlobal(Offset.zero) & box.size : null;
    try {
      final bytes = await _service.generate(
        markdown: widget.markdown,
        profile: profile,
        title: widget.title,
        format: _previewFormat,
        baseDir: _baseDir,
      );
      await Printing.sharePdf(
          bytes: bytes, filename: '$safe.pdf', bounds: bounds);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  /// The right-aligned action icons: profile management, a divider, then the
  /// document/output actions (print, share, save-as-PDF).
  List<Widget> _profileActions(
    PrintProfile selected,
    List<PrintProfile> profiles,
    PrintProfileService profilesService,
    ColorScheme cs,
  ) {
    final isDefault = _selectedId == profilesService.defaultId;
    final hasPath = widget.docPath != null;
    final assigned =
        hasPath && profilesService.assignedId(widget.docPath) == _selectedId;
    return [
      // --- Group 1: profile management ---
      IconButton(
        tooltip: 'Edit profile',
        icon: const Icon(Icons.edit_rounded),
        onPressed: () => _editProfile(selected, isNew: false),
      ),
      IconButton(
        tooltip: 'New profile',
        icon: const Icon(Icons.add_rounded),
        onPressed: () => _editProfile(
          PrintProfile(id: _newId(), name: 'New profile'),
          isNew: true,
        ),
      ),
      IconButton(
        tooltip: 'Import… (.json)',
        icon: const Icon(Icons.upload_file_rounded),
        onPressed: _importProfile,
      ),
      IconButton(
        tooltip: 'Export… (.json)',
        icon: const Icon(Icons.download_rounded),
        onPressed: () => _exportProfile(selected),
      ),
      if (profiles.length > 1)
        IconButton(
          tooltip: 'Delete profile',
          icon: const Icon(Icons.delete_outline_rounded),
          color: cs.error,
          onPressed: () async {
            await profilesService.delete(selected.id);
            if (mounted) setState(() => _previewEpoch++);
          },
        ),
      // Make this profile the global default.
      IconButton(
        tooltip: isDefault
            ? 'This is the default profile'
            : 'Set as default profile',
        icon: Icon(isDefault ? Icons.star_rounded : Icons.star_border_rounded),
        color: isDefault ? cs.primary : null,
        onPressed:
            isDefault ? null : () => profilesService.setDefault(_selectedId),
      ),
      // Pin this profile to the current file ("use for this document"): it is
      // auto-selected next time you print/export it.
      IconButton(
        tooltip: !hasPath
            ? 'Save the file first to always use this profile for it'
            : (assigned
                ? 'Always using this profile for this file — tap to stop'
                : 'Always use this profile for this file'),
        icon: Icon(assigned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
        color: assigned ? cs.primary : null,
        onPressed: !hasPath ? null : () => _togglePin(assigned),
      ),
      // Divider before the output actions.
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: SizedBox(
          height: 24,
          child: VerticalDivider(width: 1, color: cs.outlineVariant),
        ),
      ),
      // --- Group 2: output actions (moved up from the preview's bottom bar so
      // all the controls live in one place). ---
      IconButton(
        tooltip: 'Print…',
        icon: const Icon(Icons.print_outlined),
        onPressed: () => _print(selected),
      ),
      IconButton(
        key: _shareButtonKey,
        tooltip: 'Share PDF',
        icon: const Icon(Icons.ios_share_rounded),
        onPressed: () => _share(selected),
      ),
      // Direct vector export — keeps selectable text, unlike printing to a
      // virtual PDF printer.
      IconButton(
        tooltip: 'Save as PDF (selectable text)',
        icon: const Icon(Icons.picture_as_pdf_outlined),
        onPressed: () => _savePdf(selected),
      ),
    ];
  }

  /// Save the rendered document straight to a `.pdf` file. Unlike printing to a
  /// virtual "PDF printer" — which on Windows rasterises each page into a bitmap
  /// (no selectable text, large file, fuzzy) — this writes the vector PDF bytes
  /// we generate, so headings and body text stay real, selectable text.
  Future<void> _savePdf(PrintProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final safe = widget.title.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    Uint8List bytes;
    try {
      bytes = await _service.generate(
        markdown: widget.markdown,
        profile: profile,
        title: widget.title,
        // Match the size/orientation the user is previewing.
        format: _previewFormat,
        baseDir: _baseDir,
      );
    } catch (e) {
      if (mounted) {
        messenger
            .showSnackBar(SnackBar(content: Text('Could not build PDF: $e')));
      }
      return;
    }
    try {
      // On desktop saveFile only returns the chosen path (it doesn't reliably
      // write the bytes), so we write them ourselves; on mobile/web we hand the
      // bytes to saveFile.
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Save as PDF',
        fileName: '$safe.pdf',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: isDesktop ? null : bytes,
      );
      if (path == null) return; // cancelled
      if (isDesktop) await File(path).writeAsBytes(bytes);
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
      return;
    }
    if (mounted) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Saved PDF with selectable text')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profilesService = context.watch<PrintProfileService>();
    final profiles = profilesService.profiles;
    if (!profiles.any((p) => p.id == _selectedId)) {
      _selectedId = profiles.first.id;
    }
    final selected = profilesService.byId(_selectedId);
    final cs = Theme.of(context).colorScheme;

    // No Scaffold/AppBar of its own: this view fills a workspace tab, so the
    // tab strip provides the title and the close affordance.
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The dropdown fills the row and the action icons sit
                // right-aligned in two groups (profile management | output).
                // On comfortable widths the dropdown expands and the icons
                // show at natural width; on narrow widths the icons become a
                // horizontal scroll view so the row can never overflow.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final dropdown = DropdownButtonFormField<String>(
                      // Key by selection so the field rebuilds with a valid
                      // value after a profile is created/deleted (avoids a
                      // stale/duplicate-value assertion).
                      key: ValueKey('profile-dd-$_selectedId'),
                      initialValue: _selectedId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Branding profile',
                        isDense: true,
                      ),
                      items: [
                        for (final pr in profiles)
                          DropdownMenuItem(
                            value: pr.id,
                            child: Text(
                              pr.id == profilesService.defaultId
                                  ? '${pr.name}  (default)'
                                  : pr.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) _select(v);
                      },
                    );
                    final actions = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: _profileActions(
                          selected, profiles, profilesService, cs),
                    );
                    // Enough room for the dropdown plus the icon cluster at
                    // natural width? Then expand the dropdown; otherwise let
                    // the icons scroll.
                    const comfortable = 620.0;
                    return Row(
                      children: [
                        Expanded(child: dropdown),
                        const SizedBox(width: 8),
                        if (constraints.maxWidth >= comfortable)
                          actions
                        else
                          Flexible(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              reverse: true,
                              child: actions,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: PdfPreview(
            key: ValueKey('preview-$_selectedId-$_previewEpoch'),
            // The app-wide document zoom scales the previewed page's width
            // (PdfPreview otherwise fits it to the viewport; its own pinch
            // zoom still works on top). Rendering is unaffected — zoom must
            // never change what prints.
            maxPageWidth: 700 * context.watch<ZoomController>().factor,
            // A refresh or profile switch remounts the preview; start it at
            // the page size/orientation the user was previewing so their
            // selection carries across (and Print/Save keep matching it).
            initialPageFormat: _previewFormat,
            build: (format) {
              // Remember the page size/orientation the user is currently
              // previewing so "Save as PDF" matches it (not always A4).
              _previewFormat = format;
              return _service.generate(
                markdown: widget.markdown,
                profile: selected,
                title: widget.title,
                format: format,
                baseDir: _baseDir,
              );
            },
            canChangePageFormat: true,
            canChangeOrientation: true,
            // Print/Share live in the profile row above now, so hide the
            // preview's own print/share buttons (keep page-size/orientation).
            allowPrinting: false,
            allowSharing: false,
            pdfFileName: '${widget.title}.pdf',
            loadingWidget: const Center(child: CircularProgressIndicator()),
            // The Windows "Microsoft Print to PDF" / "Adobe PDF" virtual
            // printers are flaky on repeat jobs (the spooler can refuse the
            // second one until you switch printers and back). When a print
            // fails, point the user at the reliable in-app export instead.
            onPrintError: (ctx, error) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Printing failed. To make a PDF, use the “Save as PDF” '
                    'icon above — it exports directly with selectable text.',
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
