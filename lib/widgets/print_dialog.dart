import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
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
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          // Key by selection so the field rebuilds with a valid
                          // value after a profile is created or deleted (avoids
                          // a stale/duplicate-value assertion).
                          key: ValueKey('profile-dd-$_selectedId'),
                          initialValue: _selectedId,
                          decoration: const InputDecoration(
                            labelText: 'Branding profile',
                            isDense: true,
                          ),
                          items: [
                            for (final p in profiles)
                              DropdownMenuItem(
                                value: p.id,
                                child: Text(
                                  p.id == profilesService.defaultId
                                      ? '${p.name}  (default)'
                                      : p.name,
                                ),
                              ),
                          ],
                          onChanged: (v) => setState(() {
                            _selectedId = v ?? _selectedId;
                            _previewEpoch++;
                          }),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit profile',
                        icon: const Icon(Icons.edit_rounded),
                        onPressed: () => _editProfile(selected, isNew: false),
                      ),
                      // Less-common actions in an overflow menu so the row can't
                      // overflow on narrow widths.
                      PopupMenuButton<String>(
                        tooltip: 'Profile actions',
                        onSelected: (v) async {
                          switch (v) {
                            case 'new':
                              await _editProfile(
                                  PrintProfile(
                                      id: _newId(), name: 'New profile'),
                                  isNew: true);
                              break;
                            case 'import':
                              await _importProfile();
                              break;
                            case 'export':
                              await _exportProfile(selected);
                              break;
                            case 'delete':
                              await profilesService.delete(selected.id);
                              if (mounted) setState(() => _previewEpoch++);
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'new', child: Text('New profile')),
                          const PopupMenuItem(
                              value: 'import', child: Text('Import… (.json)')),
                          const PopupMenuItem(
                              value: 'export', child: Text('Export… (.json)')),
                          if (profiles.length > 1)
                            PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete',
                                    style: TextStyle(color: cs.error))),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_selectedId != profilesService.defaultId)
                        ActionChip(
                          avatar:
                              const Icon(Icons.star_outline_rounded, size: 18),
                          label: const Text('Set as default'),
                          onPressed: () =>
                              profilesService.setDefault(_selectedId),
                        ),
                      if (widget.docPath != null)
                        _AssignChip(
                          assigned:
                              profilesService.assignedId(widget.docPath) ==
                                  _selectedId,
                          onToggle: (assign) =>
                              profilesService.assignToDocument(
                            widget.docPath!,
                            assign ? _selectedId : null,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: PdfPreview(
              key: ValueKey('preview-$_selectedId-$_previewEpoch'),
              build: (format) => _service.generate(
                markdown: widget.markdown,
                profile: selected,
                title: widget.title,
                format: format,
                baseDir:
                    widget.docPath != null ? p.dirname(widget.docPath!) : null,
              ),
              canChangePageFormat: true,
              canChangeOrientation: true,
              allowPrinting: true,
              allowSharing: true,
              pdfFileName: '${widget.title}.pdf',
              loadingWidget: const Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssignChip extends StatelessWidget {
  const _AssignChip({required this.assigned, required this.onToggle});

  final bool assigned;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      avatar: Icon(
        assigned ? Icons.link_rounded : Icons.link_off_rounded,
        size: 18,
      ),
      label: const Text('Use for this document'),
      selected: assigned,
      onSelected: onToggle,
    );
  }
}
