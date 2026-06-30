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
import 'print_profile_editor.dart';

/// Full-screen print / PDF-export experience: choose a branding profile, preview
/// the rendered document, then print or share. Profiles can be created, edited,
/// set as default, and associated with the current document.
class PrintDialog extends StatefulWidget {
  const PrintDialog({
    super.key,
    required this.markdown,
    required this.title,
    required this.docPath,
  });

  final String markdown;
  final String title;
  final String? docPath;

  static Future<void> show(
    BuildContext context, {
    required String markdown,
    required String title,
    required String? docPath,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) =>
            PrintDialog(markdown: markdown, title: title, docPath: docPath),
      ),
    );
  }

  @override
  State<PrintDialog> createState() => _PrintDialogState();
}

class _PrintDialogState extends State<PrintDialog> {
  final _service = PrintService();
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

  Future<void> _editProfile(PrintProfile profile, {required bool isNew}) async {
    final result = await Navigator.of(context).push<PrintProfile>(
      MaterialPageRoute(builder: (_) => PrintProfileEditor(profile: profile)),
    );
    if (result == null || !mounted) return;
    await context.read<PrintProfileService>().upsert(result);
    setState(() {
      _selectedId = result.id;
      _previewEpoch++;
    });
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
    setState(() {
      _selectedId = profile.id;
      _previewEpoch++;
    });
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
      messenger.showSnackBar(
          SnackBar(content: Text('Exported "${profile.name}"')));
    }
  }

  String? get _baseDir =>
      widget.docPath != null ? p.dirname(widget.docPath!) : null;

  /// Open the OS print dialog for the rendered document. The print dialog picks
  /// the paper format, so we (re)build at whatever format it asks for.
  Future<void> _print(PrintProfile profile) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Printing.layoutPdf(
        name: widget.title,
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
    try {
      final bytes = await _service.generate(
        markdown: widget.markdown,
        profile: profile,
        title: widget.title,
        format: _previewFormat,
        baseDir: _baseDir,
      );
      await Printing.sharePdf(bytes: bytes, filename: '$safe.pdf');
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
        tooltip:
            isDefault ? 'This is the default profile' : 'Set as default profile',
        icon: Icon(isDefault ? Icons.star_rounded : Icons.star_border_rounded),
        color: isDefault ? cs.primary : null,
        onPressed: isDefault
            ? null
            : () => profilesService.setDefault(_selectedId),
      ),
      // Pin this profile to the current file ("use for this document"): it is
      // auto-selected next time you print/export it.
      IconButton(
        tooltip: !hasPath
            ? 'Save the file first to always use this profile for it'
            : (assigned
                ? 'Always using this profile for this file — tap to stop'
                : 'Always use this profile for this file'),
        icon: Icon(
            assigned ? Icons.push_pin_rounded : Icons.push_pin_outlined),
        color: assigned ? cs.primary : null,
        onPressed: !hasPath
            ? null
            : () => profilesService.assignToDocument(
                  widget.docPath!,
                  assigned ? null : _selectedId,
                ),
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Print / Export PDF'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
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
                        onChanged: (v) => setState(() {
                          _selectedId = v ?? _selectedId;
                          _previewEpoch++;
                        }),
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
      ),
    );
  }
}
