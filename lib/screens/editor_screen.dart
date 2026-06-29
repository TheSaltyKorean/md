import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/editor_mode.dart';
import '../services/file_association_service.dart';
import '../services/file_service.dart';
import '../state/document_controller.dart';
import '../state/theme_controller.dart';
import '../state/workspace_controller.dart';
import '../widgets/format_toolbar.dart';
import '../widgets/preview_view.dart';
import '../widgets/print_dialog.dart';
import '../widgets/split_view.dart';
import '../widgets/wysiwyg_view.dart';

/// Stateless [FileService] shared by the screen's commands.
final FileService _fileService = FileService();

/// The primary screen: a tab strip + toolbar over the active document rendered
/// in its current [EditorMode]. Stateful so it can react to one-shot document
/// events (auto-reload notice, external-change conflict) on the active tab.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  DocumentController? _bannerDoc;
  bool _conflictShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePromptAssociation());
  }

  @override
  void dispose() {
    _bannerDoc?.removeListener(_onActiveDocChanged);
    super.dispose();
  }

  /// On first eligible launch, offer to register the app as the `.md` handler.
  Future<void> _maybePromptAssociation() async {
    if (!mounted) return;
    final service = context.read<FileAssociationService>();
    if (!await service.shouldPrompt() || !mounted) return;

    final choice = await showDialog<_AssocChoice>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.description_outlined),
        title: const Text('Open .md files with Markdown Studio?'),
        content: const Text(
          'Make Markdown Studio a handler for Markdown (.md) files? '
          'On Windows you can confirm it as the default in the Settings pane '
          'that opens.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _AssocChoice.never),
            child: const Text("Don't ask again"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _AssocChoice.notNow),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _AssocChoice.associate),
            child: const Text('Associate'),
          ),
        ],
      ),
    );

    if (!mounted || choice == null || choice == _AssocChoice.notNow) return;

    if (choice == _AssocChoice.never) {
      await service.markDecided();
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final ok = await service.associate();
    await service.markDecided();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? 'Registered as a .md handler.'
            : 'Could not register the association automatically.'),
      ),
    );
  }

  void _onActiveDocChanged() => _scheduleBannerCheck();

  void _scheduleBannerCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _runBannerCheck());
  }

  void _runBannerCheck() {
    if (!mounted) return;
    final doc = context.read<WorkspaceController>().active;
    final messenger = ScaffoldMessenger.of(context);

    if (doc.takeAutoReloadNotice()) {
      messenger.hideCurrentMaterialBanner();
      messenger
          .showSnackBar(const SnackBar(content: Text('Reloaded from disk')));
    }

    if (doc.hasExternalConflict) {
      if (!_conflictShown) {
        _conflictShown = true;
        messenger.showMaterialBanner(_conflictBanner(messenger, doc));
      }
    } else if (_conflictShown) {
      _conflictShown = false;
      messenger.hideCurrentMaterialBanner();
    }
  }

  MaterialBanner _conflictBanner(
      ScaffoldMessengerState messenger, DocumentController doc) {
    return MaterialBanner(
      leading: const Icon(Icons.sync_problem_outlined),
      content: Text(
        doc.isDirty
            ? 'This file changed on disk, and you have unsaved edits.'
            : 'This file changed on disk.',
      ),
      actions: [
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            _conflictShown = false;
            doc.applyExternalChange();
          },
          child: const Text('Reload'),
        ),
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            _conflictShown = false;
            doc.keepMineAfterExternalChange();
          },
          child: const Text('Keep mine'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WorkspaceController>();
    final theme = context.watch<ThemeController>();
    final active = ws.active;

    // Keep the banner listener attached to whichever document is active.
    if (!identical(active, _bannerDoc)) {
      _bannerDoc?.removeListener(_onActiveDocChanged);
      _bannerDoc = active;
      _bannerDoc!.addListener(_onActiveDocChanged);
      _conflictShown = false;
      _scheduleBannerCheck();
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        // The open-document tabs sit where the filename would be.
        title: _TabStrip(workspace: ws, onClose: _closeTab),
        actions: _actions(context, ws, active, theme),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormatToolbar(controller: active),
              _ModeBar(doc: active),
            ],
          ),
        ),
      ),
      body: _body(active),
    );
  }

  Widget _body(DocumentController doc) {
    switch (doc.mode) {
      case EditorMode.wysiwyg:
        return WysiwygView(controller: doc);
      case EditorMode.split:
        return SplitView(controller: doc);
      case EditorMode.preview:
        return PreviewView(markdown: doc.currentMarkdown());
    }
  }

  List<Widget> _actions(
    BuildContext context,
    WorkspaceController ws,
    DocumentController active,
    ThemeController theme,
  ) {
    final cs = Theme.of(context).colorScheme;
    return [
      IconButton(
        tooltip: 'Open',
        icon: const Icon(Icons.folder_open_outlined),
        onPressed: () => _open(context, ws),
      ),
      IconButton(
        tooltip: 'Save',
        icon: const Icon(Icons.save_outlined),
        onPressed: () => _save(context, active),
      ),
      IconButton(
        tooltip: 'Print / Export PDF',
        icon: const Icon(Icons.print_outlined),
        onPressed: () => _print(context, active),
      ),
      IconButton(
        isSelected: ws.autoReload,
        tooltip: ws.autoReload
            ? 'Auto-reload on: external changes load automatically'
            : 'Auto-reload off: you save manually',
        icon: const Icon(Icons.sync_disabled_outlined),
        selectedIcon: Icon(Icons.sync_outlined, color: cs.primary),
        onPressed: () => ws.setAutoReload(!ws.autoReload),
      ),
      IconButton(
        tooltip: 'Theme: ${theme.mode.name}',
        icon: Icon(switch (theme.mode) {
          ThemeMode.system => Icons.brightness_auto_outlined,
          ThemeMode.light => Icons.light_mode_outlined,
          ThemeMode.dark => Icons.dark_mode_outlined,
        }),
        onPressed: theme.cycle,
      ),
      PopupMenuButton<String>(
        onSelected: (value) => _onMenu(context, ws, active, value),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'new', child: Text('New tab')),
          PopupMenuItem(value: 'saveAs', child: Text('Save As…')),
          PopupMenuItem(value: 'about', child: Text('About')),
        ],
      ),
    ];
  }

  // --- Commands ---------------------------------------------------------------

  Future<bool> _confirmDiscard(BuildContext context, String what) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: Text('$what has unsaved changes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _open(BuildContext context, WorkspaceController ws) async {
    final opened = await _fileService.open();
    for (final doc in opened) {
      ws.openDocument(doc.content, path: doc.path);
    }
  }

  Future<void> _save(BuildContext context, DocumentController doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final markdown = doc.currentMarkdown();
    if (doc.filePath != null) {
      final saved = await _fileService.save(markdown, doc.filePath!);
      if (saved != null) {
        doc.markSaved(saved, markdown);
        messenger.showSnackBar(SnackBar(content: Text('Saved ${doc.title}')));
      } else {
        messenger.showSnackBar(const SnackBar(content: Text('Save failed')));
      }
    } else {
      await _saveAs(context, doc);
    }
  }

  Future<void> _saveAs(BuildContext context, DocumentController doc) async {
    final messenger = ScaffoldMessenger.of(context);
    final markdown = doc.currentMarkdown();
    final path =
        await _fileService.saveAs(markdown, suggestedName: doc.suggestedFileName);
    if (path != null) {
      doc.markSaved(path, markdown);
      messenger
          .showSnackBar(SnackBar(content: Text('Saved ${p.basename(path)}')));
    }
  }

  Future<void> _print(BuildContext context, DocumentController doc) async {
    final title = doc.filePath != null
        ? p.basenameWithoutExtension(doc.filePath!)
        : 'Untitled';
    await PrintDialog.show(
      context,
      markdown: doc.currentMarkdown(),
      title: title,
      docPath: doc.filePath,
    );
  }

  Future<void> _closeTab(int index) async {
    final ws = context.read<WorkspaceController>();
    if (index < 0 || index >= ws.documents.length) return;
    final doc = ws.documents[index];
    if (doc.isDirty) {
      final ok = await _confirmDiscard(context, '"${doc.title}"');
      if (!ok) return;
    }
    ws.closeAt(index);
  }

  void _onMenu(BuildContext context, WorkspaceController ws,
      DocumentController active, String value) {
    switch (value) {
      case 'new':
        ws.newDocument();
        break;
      case 'saveAs':
        _saveAs(context, active);
        break;
      case 'about':
        showAboutDialog(
          context: context,
          applicationName: 'Markdown Studio',
          applicationVersion: '1.0.0',
          applicationLegalese:
              'A cross-platform Markdown viewer & WYSIWYG editor.',
        );
        break;
    }
  }
}

enum _AssocChoice { associate, notNow, never }

/// Horizontal, scrollable strip of open-document tabs plus a "new tab" button.
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.workspace, required this.onClose});

  final WorkspaceController workspace;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final docs = workspace.documents;
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: docs.length,
              itemBuilder: (context, i) => _Tab(
                doc: docs[i],
                selected: i == workspace.activeIndex,
                onTap: () => workspace.select(i),
                onClose: () => onClose(i),
              ),
            ),
          ),
          IconButton(
            tooltip: 'New tab',
            icon: const Icon(Icons.add_rounded),
            onPressed: workspace.newDocument,
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.doc,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final DocumentController doc;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.only(left: 14, right: 6),
        decoration: BoxDecoration(
          color: selected ? cs.surface : Colors.transparent,
          border: Border(
            bottom: BorderSide(
              color: selected ? cs.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (doc.isDirty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.circle, size: 8, color: cs.primary),
              ),
            Flexible(
              child: Text(
                doc.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded),
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// The per-document view-mode selector shown beneath the tab strip.
class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.doc});

  final DocumentController doc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      alignment: Alignment.centerLeft,
      child: SegmentedButton<EditorMode>(
        showSelectedIcon: false,
        segments: [
          for (final m in EditorMode.values)
            ButtonSegment(
              value: m,
              icon: Icon(m.icon, size: 18),
              label: Text(m.label),
            ),
        ],
        selected: {doc.mode},
        onSelectionChanged: (s) => doc.setMode(s.first),
      ),
    );
  }
}
