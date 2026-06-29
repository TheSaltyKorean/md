import 'package:flutter/material.dart';
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
                      IconButton(
                        tooltip: 'New profile',
                        icon: const Icon(Icons.add_rounded),
                        onPressed: () => _editProfile(
                          PrintProfile(id: _newId(), name: 'New profile'),
                          isNew: true,
                        ),
                      ),
                      if (profiles.length > 1)
                        IconButton(
                          tooltip: 'Delete profile',
                          icon: Icon(Icons.delete_outline_rounded,
                              color: cs.error),
                          onPressed: () async {
                            await profilesService.delete(selected.id);
                            setState(() => _previewEpoch++);
                          },
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
