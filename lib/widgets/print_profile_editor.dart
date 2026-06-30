import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/print_profile.dart';
import '../services/print_service.dart';

/// Full-screen editor for creating or editing a [PrintProfile]. Returns the
/// edited profile via [Navigator.pop], or null if cancelled.
class PrintProfileEditor extends StatefulWidget {
  const PrintProfileEditor({super.key, required this.profile});

  /// The profile to edit. For a new profile, pass a freshly-constructed one.
  final PrintProfile profile;

  @override
  State<PrintProfileEditor> createState() => _PrintProfileEditorState();
}

class _PrintProfileEditorState extends State<PrintProfileEditor> {
  late TextEditingController _name;
  late TextEditingController _company;
  late TextEditingController _header;
  late TextEditingController _footer;
  late TextEditingController _watermark;
  late TextEditingController _confidential;

  late String _font;
  late int _primary;
  late int _textColor;
  late String? _logoPath;
  late bool _pageNumbers;
  late bool _date;
  late bool _titleInHeader;
  late double _margin;
  late bool _accentRule;
  late bool _headingRule;
  late bool _footerCentered;
  late bool _coverLogo;
  late bool _useAccent;
  late int _accent;

  static const _swatches = <int>[
    0xFF0D3B66, // navy
    0xFF1A237E, // indigo
    0xFF4C6FFF, // brand blue
    0xFF00695C, // teal
    0xFF2E7D32, // green
    0xFF6A1B9A, // purple
    0xFFB71C1C, // red
    0xFFEF6C00, // orange
    0xFF37474F, // slate
    0xFF1A1A1A, // near-black
  ];

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name = TextEditingController(text: p.name);
    _company = TextEditingController(text: p.companyName ?? '');
    _header = TextEditingController(text: p.headerText ?? '');
    _footer = TextEditingController(text: p.footerText ?? '');
    _watermark = TextEditingController(text: p.watermarkText ?? '');
    _confidential = TextEditingController(text: p.confidentialLabel ?? '');
    _font = PrintService.availableFonts.contains(p.fontFamily)
        ? p.fontFamily
        : PrintService.availableFonts.first;
    _primary = p.primaryColor;
    _textColor = p.textColor;
    _logoPath = p.logoPath;
    _pageNumbers = p.showPageNumbers;
    _date = p.showDate;
    _titleInHeader = p.showTitleInHeader;
    _margin = p.marginCm;
    _accentRule = p.accentRule;
    _headingRule = p.headingRule;
    _footerCentered = p.footerCentered;
    _coverLogo = p.coverLogo;
    _useAccent = p.accentColor != null;
    _accent = p.accentColor ?? p.primaryColor;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _company,
      _header,
      _footer,
      _watermark,
      _confidential,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _trimOrNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  PrintProfile _assemble() => widget.profile.copyWith(
        name:
            _name.text.trim().isEmpty ? 'Untitled profile' : _name.text.trim(),
        companyName: _trimOrNull(_company),
        headerText: _trimOrNull(_header),
        footerText: _trimOrNull(_footer),
        watermarkText: _trimOrNull(_watermark),
        confidentialLabel: _trimOrNull(_confidential),
        fontFamily: _font,
        primaryColor: _primary,
        textColor: _textColor,
        logoPath: _logoPath,
        showPageNumbers: _pageNumbers,
        showDate: _date,
        showTitleInHeader: _titleInHeader,
        marginCm: _margin,
        accentRule: _accentRule,
        headingRule: _headingRule,
        footerCentered: _footerCentered,
        coverLogo: _coverLogo,
        accentColor: _useAccent ? _accent : null,
      );

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a logo image',
      type: FileType.image,
      withData: true,
    );
    if (result == null) return;
    final picked = result.files.single;
    try {
      final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();
      // Copy into app-owned storage so the path stays readable across launches
      // (a raw picker path loses access in the macOS sandbox after relaunch).
      final supportDir = await getApplicationSupportDirectory();
      final logosDir = Directory(p.join(supportDir.path, 'profile_logos'));
      await logosDir.create(recursive: true);
      final ext = p.extension(picked.name);
      final dest = File(p.join(
          logosDir.path, '${DateTime.now().microsecondsSinceEpoch}$ext'));
      await dest.writeAsBytes(bytes);
      if (mounted) setState(() => _logoPath = dest.path);
    } catch (_) {
      // Fall back to the raw path if copying fails.
      if (picked.path != null && mounted) {
        setState(() => _logoPath = picked.path);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Print profile'),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(_assemble()),
            icon: const Icon(Icons.check_rounded),
            label: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          _section('Identity'),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Profile name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _company,
            decoration: const InputDecoration(
              labelText: 'Company / entity (header & footer)',
              hintText: 'e.g. Your Company',
            ),
          ),
          const SizedBox(height: 20),
          _section('Branding'),
          _logoRow(cs),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _font,
            decoration: const InputDecoration(labelText: 'Font family'),
            items: [
              for (final f in PrintService.availableFonts)
                DropdownMenuItem(value: f, child: Text(f)),
            ],
            onChanged: (v) => setState(() => _font = v ?? _font),
          ),
          const SizedBox(height: 16),
          _colorField('Primary / accent colour', _primary,
              (c) => setState(() => _primary = c)),
          const SizedBox(height: 12),
          _colorField('Body text colour', _textColor,
              (c) => setState(() => _textColor = c)),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _accentRule,
            onChanged: (v) => setState(() => _accentRule = v),
            title: const Text('Accent rule under header / above footer'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 20),
          _section('Branded styling'),
          SwitchListTile(
            value: _headingRule,
            onChanged: (v) => setState(() => _headingRule = v),
            title: const Text('Underline section headings'),
            subtitle: const Text('Primary-colour rule beneath h2/h3 headings'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _footerCentered,
            onChanged: (v) => setState(() => _footerCentered = v),
            title: const Text('Centred footer with page count'),
            subtitle: const Text('“Footer — Title | Page N of M”, hairline above'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _coverLogo,
            onChanged: (v) => setState(() => _coverLogo = v),
            title: const Text('Logo as cover (top of first page)'),
            subtitle:
                const Text('Logo once at the top; omitted from the running header'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _useAccent,
            onChanged: (v) => setState(() => _useAccent = v),
            title: const Text('Separate link / accent colour'),
            subtitle: const Text('Otherwise links use the primary colour'),
            contentPadding: EdgeInsets.zero,
          ),
          if (_useAccent) ...[
            const SizedBox(height: 8),
            _colorField('Link / accent colour', _accent,
                (c) => setState(() => _accent = c)),
          ],
          const SizedBox(height: 20),
          _section('Header & footer'),
          TextField(
            controller: _header,
            decoration: const InputDecoration(
              labelText: 'Header text (optional)',
              hintText: 'Leave blank to use the document title',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _footer,
            decoration: const InputDecoration(
              labelText: 'Footer text (optional)',
              hintText: 'e.g. © 2026 Your Company',
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            value: _titleInHeader,
            onChanged: (v) => setState(() => _titleInHeader = v),
            title: const Text('Show document title in header'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _pageNumbers,
            onChanged: (v) => setState(() => _pageNumbers = v),
            title: const Text('Show page numbers'),
            contentPadding: EdgeInsets.zero,
          ),
          SwitchListTile(
            value: _date,
            onChanged: (v) => setState(() => _date = v),
            title: const Text('Show date'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 20),
          _section('Confidentiality'),
          TextField(
            controller: _confidential,
            decoration: const InputDecoration(
              labelText: 'Classification label (optional)',
              hintText: 'e.g. CONFIDENTIAL, INTERNAL USE ONLY',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _watermark,
            decoration: const InputDecoration(
              labelText: 'Diagonal watermark text (optional)',
              hintText: 'e.g. CONFIDENTIAL',
            ),
          ),
          const SizedBox(height: 20),
          _section('Layout'),
          Row(
            children: [
              const Text('Margin'),
              Expanded(
                child: Slider(
                  value: _margin,
                  min: 1.0,
                  max: 3.5,
                  divisions: 10,
                  label: '${_margin.toStringAsFixed(1)} cm',
                  onChanged: (v) => setState(() => _margin = v),
                ),
              ),
              Text('${_margin.toStringAsFixed(1)} cm'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                letterSpacing: 1,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
        ),
      );

  Widget _logoRow(ColorScheme cs) {
    return Row(
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.outlineVariant),
          ),
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          child: _logoPath == null
              ? Icon(Icons.image_outlined, color: cs.onSurfaceVariant)
              : Image.file(
                  File(_logoPath!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      Icon(Icons.broken_image_outlined, color: cs.error),
                ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _logoPath == null
                    ? 'No logo selected'
                    : _logoPath!.split(RegExp(r'[\\/]')).last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _pickLogo,
                    icon: const Icon(Icons.upload_rounded, size: 18),
                    label: const Text('Choose logo'),
                  ),
                  if (_logoPath != null)
                    TextButton(
                      onPressed: () => setState(() => _logoPath = null),
                      child: const Text('Remove'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _colorField(String label, int value, ValueChanged<int> onPick) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final c in _swatches)
              GestureDetector(
                onTap: () => onPick(c),
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: value == c
                          ? Theme.of(context).colorScheme.onSurface
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: value == c
                      ? const Icon(Icons.check, color: Colors.white, size: 18)
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
