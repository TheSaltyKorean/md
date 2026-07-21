import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HardwareKeyboard, LogicalKeyboardKey, SystemNavigator;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import '../models/editor_mode.dart';
import '../services/file_association_service.dart';
import '../services/file_service.dart';
import '../services/print_profile_service.dart';
import '../services/single_instance_service.dart';
import '../services/update_service.dart';
import '../state/document_controller.dart';
import '../state/theme_controller.dart';
import '../state/workspace_controller.dart';
import '../state/zoom_controller.dart';
import '../widgets/find_controller.dart';
import '../widgets/format_toolbar.dart';
import '../widgets/preview_find_view.dart';
import '../widgets/print_preview_view.dart';
import '../widgets/raw_view.dart';
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

class _EditorScreenState extends State<EditorScreen>
    with WindowListener, WidgetsBindingObserver {
  DocumentController? _bannerDoc;
  bool _conflictShown = false;
  bool _dragging = false;

  // --- Pinch-to-zoom (touch) --------------------------------------------------
  // Tracked via a Listener (which observes pointers without claiming the
  // gesture arena) so a two-finger pinch drives the document zoom while a
  // one-finger drag still scrolls the view untouched. Works for every view,
  // including the print preview (the same ZoomController scales its surface).
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartFactor = 1.0;

  /// Shared find & replace state; the bar itself lives inside the mounted source
  /// view (see [_body]).
  final FindController _find = FindController();

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    if (_isDesktop) {
      windowManager.addListener(this);
      // Intercept the window-close button so we can confirm unsaved changes.
      windowManager.setPreventClose(true);
    }
    // Mobile has no window-close event: flush the session when the app is
    // paused/backgrounded so edits aren't lost if it's then swiped away
    // before the debounce fires.
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _maybePromptAssociation());
    // Launch-time update check (single version request; menu-toggleable).
    // A found update gets an explicit prompt — the toolbar chip alone is
    // easy to miss (field feedback).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final updates = context.read<UpdateController>();
      if (!await updates.check()) return;
      if (!mounted) return;
      final info = updates.available!;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Markdown Studio ${info.version} is available.'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
            label: 'Update', onPressed: () => _startUpdate(info)),
      ));
    });
    // Rebuild when find opens/closes so the floating toolbar can yield to it.
    _find.addListener(_onFindChanged);
  }

  void _onFindChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_isDesktop) windowManager.removeListener(this);
    WidgetsBinding.instance.removeObserver(this);
    _bannerDoc?.removeListener(_onActiveDocChanged);
    _find.removeListener(_onFindChanged);
    _find.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist the session when the app leaves the foreground (mobile has no
    // window-close hook), so a swipe-away right after an edit doesn't lose it.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      context.read<WorkspaceController>().flushSession();
    }
  }

  /// Persist the session for a clean exit and decide whether to proceed.
  /// Returns true to go ahead with the exit, false to abort it (the user
  /// cancelled a fallback discard prompt). With persistence on, a successful
  /// flush means hot exit (no prompt); a *failed* flush (disk full/unwritable)
  /// falls back to the discard warning so unsaved work isn't lost silently.
  /// Without persistence (a torn-off window), any unsaved work prompts.
  Future<bool> _prepareExit() async {
    final ws = context.read<WorkspaceController>();
    // Unsaved work worth a fallback prompt includes not just dirty buffers but
    // a clean tab with an unresolved external-change conflict: its old buffer
    // survives only in the session file, so a failed flush there must not exit
    // silently and drop the user's "Keep mine" choice.
    final anyUnsaved =
        ws.documents.any((d) => d.isDirty || d.hasExternalConflict);
    if (ws.sessionEnabled) {
      if (await ws.flushSession()) return true; // saved — hot exit
      if (!anyUnsaved) return true; // write failed but nothing to lose
    } else if (!anyUnsaved) {
      return true;
    }
    if (!mounted) return true;
    return _confirmDiscard(context, 'One or more open documents');
  }

  /// Open find (and optionally replace). Plain find works in place in the
  /// source modes AND in Preview (highlight overlay). Replace edits the source,
  /// and WYSIWYG has no in-place find, so those route to Raw first.
  void _openFind(DocumentController doc, {bool replace = false}) {
    final needsSource = replace || doc.mode == EditorMode.wysiwyg;
    if (needsSource && !doc.mode.isSource) doc.setMode(EditorMode.raw);
    replace ? _find.openReplace() : _find.openFind();
  }

  // --- Pinch-to-zoom pointer bookkeeping --------------------------------------
  // Driven from a Listener (observe-only, never claims the gesture arena), so a
  // one-finger drag keeps scrolling while a two-finger pinch scales the zoom.

  void _onPinchDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    _rebaselinePinch();
  }

  void _onPinchMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    final start = _pinchStartDistance;
    if (_pointers.length == 2 && start != null && start > 0) {
      final dist = _pinchDistance();
      if (dist != null) {
        context
            .read<ZoomController>()
            .zoomTo(_pinchStartFactor * (dist / start));
      }
    }
  }

  void _onPinchEnd(int pointer) {
    _pointers.remove(pointer);
    _rebaselinePinch();
  }

  /// Recompute the pinch baseline whenever the pointer set changes. Any change
  /// while exactly two fingers are down (including a third finger touching then
  /// one of the original pair lifting) re-anchors dist/zoom to the CURRENT
  /// pair, so the next move can't apply a ratio against a stale baseline and
  /// jump the zoom. With any other count there's no active pinch.
  void _rebaselinePinch() {
    if (_pointers.length == 2) {
      _pinchStartDistance = _pinchDistance();
      _pinchStartFactor = context.read<ZoomController>().factor;
    } else {
      _pinchStartDistance = null;
    }
  }

  double? _pinchDistance() {
    if (_pointers.length != 2) return null;
    final p = _pointers.values.toList();
    return (p[0] - p[1]).distance;
  }

  @override
  void onWindowClose() async {
    if (!await _prepareExit()) return; // user cancelled a discard prompt
    await _shutdownAndExit();
  }

  /// The unconditional tail of a window close. Confirm-discard, if wanted,
  /// happens before calling this.
  Future<void> _shutdownAndExit() async {
    await _releaseResources();
    exit(0);
  }

  /// Everything [_shutdownAndExit] does except the exit itself — the update
  /// flow releases the app's resources FIRST, then spawns the installer,
  /// then exits, so file replacement can never race a still-shutting-down
  /// process.
  Future<void> _releaseResources() async {
    final ws = context.read<WorkspaceController>();
    final single = context.read<SingleInstanceService>();
    final theme = context.read<ThemeController>();
    final profiles = context.read<PrintProfileService>();
    final zoom = context.read<ZoomController>();
    final updates = context.read<UpdateController>();
    // The final session write already happened in _prepareExit (awaited, so
    // its success gates a discard fallback). Here we just drain the other
    // fire-and-forget preference writes.
    // Drain any preference write still in flight (UI callbacks fire-and-forget
    // setAutoReload / cycle / setDefault), so a setting changed right before
    // closing isn't lost. Bounded so a stuck write can't hang the close.
    try {
      await Future.wait([
        ws.pendingWrites,
        theme.pendingWrites,
        profiles.pendingWrites,
        zoom.pendingWrites,
        updates.pendingWrites,
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {}
    // Release the long-lived event sources (single-instance ServerSocket + file
    // watchers), then exit the process directly. windowManager.destroy() alone
    // leaves the Flutter engine lingering for many seconds on Windows; exit(0)
    // terminates immediately.
    try {
      await single.dispose();
    } catch (_) {}
    ws.disposeWatchers();
  }

  /// On first eligible launch, offer to register the app as the `.md` handler.
  Future<void> _maybePromptAssociation() async {
    if (!mounted) return;
    final service = context.read<FileAssociationService>();
    // Installed copies get their association from the installer, so the prompt
    // is only offered for portable/zip/dev builds (see shouldPrompt).
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
    final doc = context.read<WorkspaceController>().activeDocument;
    if (doc == null) return; // print preview active — nothing to check
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
    final zoom = context.watch<ZoomController>();
    final activeTab = ws.activeTab;
    // Null when the active tab is a print preview rather than a document.
    final active = ws.activeDocument;

    // Find mounts inside a source view or in Preview (which highlights matches
    // in place). Preview supports plain find only — replace edits the source —
    // so it's not findable while the replace bar is open. If the active view
    // supports neither (switched to Edit, replace open over Preview, or moved to
    // a tab that is), close find so no invisible state lingers.
    bool findable(EditorMode? m) =>
        m != null &&
        (m.isSource || (m == EditorMode.preview && !_find.replaceVisible));
    if (_find.visible && !findable(active?.mode)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final doc = mounted ? ws.activeDocument : null;
        if (mounted && !findable(doc?.mode)) _find.hide();
      });
    }

    // Keep the banner listener attached to whichever document is active.
    if (!identical(active, _bannerDoc)) {
      _bannerDoc?.removeListener(_onActiveDocChanged);
      _bannerDoc = active;
      _bannerDoc?.addListener(_onActiveDocChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Dismiss any banner belonging to the previously active document so its
        // Reload/Keep-mine actions can't act on the wrong tab.
        ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
        _conflictShown = false;
        _runBannerCheck();
      });
    }

    // On narrow (phone) widths the mode selector moves to its own bar and most
    // actions collapse into the overflow menu so the app bar can't overflow.
    final isNarrow = MediaQuery.sizeOf(context).width < 720;
    return PopScope(
      // Always intercept Android back so we flush the session before the app
      // exits — even when every doc is clean, the session still holds unsaved
      // state (active tab, per-tab view mode, adopted clean content) that a
      // debounced save may not have written yet. _prepareExit writes it and
      // only reports success once it's safely on disk (or, if the write fails
      // with unsaved work, the user confirms discarding).
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _prepareExit() && mounted) {
          await SystemNavigator.pop();
        }
      },
      // Find shortcuts wrap the whole Scaffold (not just the body) so Ctrl/Cmd+F,
      // Ctrl/Cmd+H and Esc fire regardless of which chrome control (app bar,
      // mode toggle, …) currently holds focus. Autofocus so they also work from
      // the initial Preview, which requests no focus of its own.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            if (active != null) _openFind(active);
          },
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () {
            if (active != null) _openFind(active);
          },
          const SingleActivator(LogicalKeyboardKey.keyH, control: true): () {
            if (active != null) _openFind(active, replace: true);
          },
          const SingleActivator(LogicalKeyboardKey.keyH, meta: true): () {
            if (active != null) _openFind(active, replace: true);
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_find.visible) _find.hide();
          },
          // Browser-style zoom. "+" is Shift+= on most layouts, so both the
          // plain and shifted "=" activate zoom-in; numpad keys included.
          // On print-preview tabs the same level scales the preview's page
          // width (user request) — PdfPreview's own pinch zoom still works
          // on top of it.
          for (final key in [
            LogicalKeyboardKey.equal,
            LogicalKeyboardKey.add, // layouts with a dedicated "+" key
            LogicalKeyboardKey.numpadAdd,
          ]) ...{
            SingleActivator(key, control: true): zoom.zoomIn,
            SingleActivator(key, control: true, shift: true): zoom.zoomIn,
            SingleActivator(key, meta: true): zoom.zoomIn,
            SingleActivator(key, meta: true, shift: true): zoom.zoomIn,
          },
          for (final key in [
            LogicalKeyboardKey.minus,
            LogicalKeyboardKey.numpadSubtract,
          ]) ...{
            SingleActivator(key, control: true): zoom.zoomOut,
            SingleActivator(key, meta: true): zoom.zoomOut,
          },
          for (final key in [
            LogicalKeyboardKey.digit0,
            LogicalKeyboardKey.numpad0,
          ]) ...{
            SingleActivator(key, control: true): zoom.reset,
            SingleActivator(key, meta: true): zoom.reset,
          },
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              titleSpacing: 8,
              centerTitle: false,
              automaticallyImplyLeading: false,
              // Top row: the toolbar icons, left-aligned (horizontally
              // scrollable if they can't all fit); the overflow hamburger pins
              // to the far right via [actions]. The open-document tabs sit on
              // their own row(s) below the app bar (see body), wrapping into
              // additional rows as they overflow.
              title: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _toolbarIcons(context, ws, active, theme, isNarrow),
                ),
              ),
              actions: [_overflowMenu(context, ws, active, isNarrow)],
            ),
            body: Column(
              children: [
                // Open-document tabs on their own row(s), below the toolbar;
                // they wrap into additional rows as more tabs open.
                _TabStrip(
                  workspace: ws,
                  onClose: _closeTab,
                  onTabDragEnd: _onTabDragEnd,
                ),
                Expanded(
                  child: DropTarget(
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: (detail) => _onFilesDropped(detail, ws),
                    // Ctrl/Cmd + mouse wheel zooms, like a browser; a two-finger
                    // pinch zooms on touch. A raw Listener observes without
                    // consuming, so a one-finger drag still scrolls normally — an
                    // accepted trade-off for not swallowing normal scrolling.
                    child: Listener(
                      onPointerSignal: (event) {
                        if (event is! PointerScrollEvent) return;
                        final keys = HardwareKeyboard.instance;
                        if (!keys.isControlPressed && !keys.isMetaPressed) {
                          return;
                        }
                        if (event.scrollDelta.dy == 0) return;
                        event.scrollDelta.dy < 0
                            ? zoom.zoomIn()
                            : zoom.zoomOut();
                      },
                      onPointerDown: _onPinchDown,
                      onPointerMove: _onPinchMove,
                      onPointerUp: (e) => _onPinchEnd(e.pointer),
                      onPointerCancel: (e) => _onPinchEnd(e.pointer),
                      child: LayoutBuilder(
                        builder: (context, constraints) => Stack(
                          children: [
                            Positioned.fill(child: _body(activeTab)),
                            // The floating, draggable format palette — hidden in Preview
                            // and print-preview tabs (nothing to edit there) and, in a
                            // source mode, while find is open so it can't cover the find
                            // card on narrow windows.
                            if (active != null &&
                                active.mode != EditorMode.preview &&
                                !(_find.visible && active.mode.isSource))
                              FloatingFormatToolbar(
                                controller: active,
                                area: constraints.biggest,
                              ),
                            if (_dragging) _dropHint(context),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(WorkspaceTab tab) {
    if (tab is PrintPreviewTab) {
      // Key by tab identity only: a refresh (epoch bump) must update the
      // existing State — not recreate it — so the user's profile and
      // page-format selections survive; the view re-renders the PDF itself
      // when refreshEpoch changes.
      return PrintPreviewView(
        key: ObjectKey(tab),
        markdown: tab.markdown,
        title: tab.title,
        docPath: tab.docPath,
        refreshEpoch: tab.epoch,
      );
    }
    final doc = (tab as DocumentTab).doc;
    // Key by the document so switching tabs recreates the view's State (e.g.
    // SplitView re-attaches its text listener to the new document's controller).
    final key = ValueKey(doc);
    final view = switch (doc.mode) {
      EditorMode.wysiwyg => WysiwygView(key: key, controller: doc),
      EditorMode.split => SplitView(key: key, controller: doc, find: _find),
      EditorMode.raw => RawSourceView(key: key, controller: doc, find: _find),
      EditorMode.preview =>
        PreviewFindView(key: key, markdown: doc.currentMarkdown(), find: _find),
    };
    // Document zoom, applied to document views only (print previews have
    // their own zoom, and app chrome stays at 100%). The zoom composes with
    // the inherited scaler rather than replacing it, so a platform /
    // accessibility text size keeps applying and zoom stays relative to it.
    // The source/preview panes pick this up as the ambient text scaler; the
    // WYSIWYG editor ignores MediaQuery and re-derives its
    // EditorStyle.textScaleFactor from it instead (see WysiwygView).
    final factor = context.watch<ZoomController>().factor;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: ZoomedTextScaler(MediaQuery.textScalerOf(context), factor),
      ),
      child: view,
    );
  }

  /// Compact "130%" chip shown while zoom is off default: constant feedback
  /// of the current level, and a one-click reset (also Ctrl+0).
  Widget? _zoomChip(ZoomController zoom) {
    if (zoom.isDefault) return null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: 'Zoom — click to reset to 100% (Ctrl 0)',
          child: ActionChip(
            visualDensity: VisualDensity.compact,
            label: Text(zoom.label),
            onPressed: zoom.reset,
          ),
        ),
      ),
    );
  }

  /// "Update to X.Y.Z" button, shown once a newer release is known.
  Widget? _updateChip(UpdateController updates) {
    final info = updates.available;
    if (info == null) return null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: FilledButton.tonalIcon(
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          icon: const Icon(Icons.system_update_alt_rounded, size: 18),
          label: Text('Update to ${info.version}'),
          onPressed: () => _startUpdate(info),
        ),
      ),
    );
  }

  /// [active] is null when the active tab is a print preview; document-bound
  /// actions (mode toggle, find, save, print) are then hidden or disabled.
  /// The left-aligned toolbar icons for the top app-bar row. The overflow
  /// hamburger is separate ([_overflowMenu]) so it can pin to the far right
  /// while these stay left; the open-document tabs live on their own row(s)
  /// below the app bar (see build()).
  List<Widget> _toolbarIcons(
    BuildContext context,
    WorkspaceController ws,
    DocumentController? active,
    ThemeController theme,
    bool isNarrow,
  ) {
    final cs = Theme.of(context).colorScheme;
    final zoomChip = _zoomChip(context.watch<ZoomController>());
    final updateChip = _updateChip(context.watch<UpdateController>());
    final themeIcon = Icon(switch (theme.mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    });
    final autoReloadButton = IconButton(
      isSelected: ws.autoReload,
      tooltip: ws.autoReload
          ? 'Auto-reload on: external changes load automatically'
          : 'Auto-reload off: you save manually',
      icon: const Icon(Icons.sync_disabled_outlined),
      selectedIcon: Icon(Icons.sync_outlined, color: cs.primary),
      onPressed: () => ws.setAutoReload(!ws.autoReload),
    );
    // Compact icon-only view-mode toggle (document tabs only).
    final modeToggle = active == null
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(child: _ModeToggle(doc: active)),
          );

    if (isNarrow) {
      // Phone layout: mode toggle + Save + auto-reload + theme; everything else
      // lives in the overflow menu. No update chip here: at phone widths the
      // long button starves the row; the overflow menu carries the command.
      return [
        if (modeToggle != null) modeToggle,
        if (zoomChip != null) zoomChip,
        IconButton(
          tooltip: 'Save',
          icon: const Icon(Icons.save_outlined),
          onPressed: active == null ? null : () => _save(context, active),
        ),
        autoReloadButton,
        IconButton(
            tooltip: 'Theme: ${theme.mode.name}',
            icon: themeIcon,
            onPressed: theme.cycle),
      ];
    }

    return [
      if (modeToggle != null) modeToggle,
      if (updateChip != null) updateChip,
      if (zoomChip != null) zoomChip,
      IconButton(
        tooltip: 'Open',
        icon: const Icon(Icons.folder_open_outlined),
        onPressed: () => _open(context, ws),
      ),
      IconButton(
        tooltip: 'Find (Ctrl+F)',
        icon: const Icon(Icons.search_rounded),
        onPressed: active == null ? null : () => _openFind(active),
      ),
      IconButton(
        tooltip: 'Save',
        icon: const Icon(Icons.save_outlined),
        onPressed: active == null ? null : () => _save(context, active),
      ),
      IconButton(
        tooltip: 'Print / Export PDF',
        icon: const Icon(Icons.print_outlined),
        onPressed: active == null ? null : () => _print(context, active),
      ),
      autoReloadButton,
      IconButton(
          tooltip: 'Theme: ${theme.mode.name}',
          icon: themeIcon,
          onPressed: theme.cycle),
    ];
  }

  /// The overflow (hamburger) menu, pinned to the far right of the top row.
  Widget _overflowMenu(
    BuildContext context,
    WorkspaceController ws,
    DocumentController? active,
    bool isNarrow,
  ) {
    // Document-bound commands are disabled while a print preview tab is active
    // (there is no document to act on).
    return PopupMenuButton<String>(
      onSelected: (value) => _onMenu(context, ws, active, value),
      itemBuilder: (_) => isNarrow
          ? [
              const PopupMenuItem(value: 'open', child: Text('Open…')),
              const PopupMenuItem(value: 'new', child: Text('New tab')),
              PopupMenuItem(
                  value: 'find',
                  enabled: active != null,
                  child: const Text('Find')),
              PopupMenuItem(
                  value: 'replace',
                  enabled: active != null,
                  child: const Text('Replace…')),
              PopupMenuItem(
                  value: 'save',
                  enabled: active != null,
                  child: const Text('Save')),
              PopupMenuItem(
                  value: 'saveAs',
                  enabled: active != null,
                  child: const Text('Save As…')),
              PopupMenuItem(
                  value: 'print',
                  enabled: active != null,
                  child: const Text('Print / Export PDF')),
              ..._zoomMenuItems(context),
              ..._updateMenuItems(context),
              const PopupMenuItem(
                  value: 'support', child: Text('Support the project ❤')),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ]
          : [
              const PopupMenuItem(value: 'new', child: Text('New tab')),
              // Replace edits the source, so it routes through Raw — the only
              // mouse/touch path to Replace in the wide layout.
              PopupMenuItem(
                  value: 'replace',
                  enabled: active != null,
                  child: const Text('Replace…')),
              PopupMenuItem(
                  value: 'saveAs',
                  enabled: active != null,
                  child: const Text('Save As…')),
              ..._zoomMenuItems(context),
              ..._updateMenuItems(context),
              const PopupMenuItem(
                  value: 'support', child: Text('Support the project ❤')),
              const PopupMenuItem(value: 'about', child: Text('About')),
            ],
    );
  }

  /// Update entries shared by both overflow menus.
  List<PopupMenuEntry<String>> _updateMenuItems(BuildContext context) {
    final updates = context.read<UpdateController>();
    final info = updates.available;
    return [
      PopupMenuItem(
          value: 'checkUpdates',
          child: Text(info == null
              ? 'Check for updates'
              : 'Update to ${info.version}…')),
      CheckedPopupMenuItem(
          value: 'toggleUpdateCheck',
          checked: updates.checkOnStartup,
          child: const Text('Check on startup')),
    ];
  }

  /// Zoom entries shared by both overflow menus. The current level shows on
  /// the reset item so the menu doubles as the zoom indicator.
  List<PopupMenuEntry<String>> _zoomMenuItems(BuildContext context) {
    final zoom = context.read<ZoomController>();
    return [
      PopupMenuItem(
          value: 'zoomIn',
          enabled: zoom.canZoomIn,
          child: const Text('Zoom in (Ctrl +)')),
      PopupMenuItem(
          value: 'zoomOut',
          enabled: zoom.canZoomOut,
          child: const Text('Zoom out (Ctrl −)')),
      PopupMenuItem(
          value: 'zoomReset',
          enabled: !zoom.isDefault,
          child: Text('Reset zoom — ${zoom.label} (Ctrl 0)')),
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
      ws.openDocument(doc.content,
          path: doc.path, displayName: doc.displayName);
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
    final result = await _fileService.saveAs(markdown,
        suggestedName: doc.suggestedFileName);
    if (!result.saved) return;
    if (result.path != null) {
      doc.markSaved(result.path!, markdown);
      messenger.showSnackBar(
          SnackBar(content: Text('Saved ${p.basename(result.path!)}')));
    } else {
      // Mobile: saved via the platform picker, no re-writable path to track.
      doc.markCleanSaved(markdown);
      messenger.showSnackBar(const SnackBar(content: Text('Saved')));
    }
  }

  /// Open (or refresh) the document's print preview in its own workspace tab.
  void _print(BuildContext context, DocumentController doc) {
    // Use the file name, or the display name for pathless (mobile) documents.
    final title = p.basenameWithoutExtension(doc.filePath ?? doc.title);
    context.read<WorkspaceController>().openPrintPreview(
          markdown: doc.currentMarkdown(),
          title: title,
          docPath: doc.filePath,
          // Identity key so pathless documents (which can share a title)
          // each refresh their own preview.
          sourceKey: doc,
        );
  }

  Future<void> _closeTab(int index) async {
    final ws = context.read<WorkspaceController>();
    if (index < 0 || index >= ws.tabs.length) return;
    final tab = ws.tabs[index];
    // Prompt for a dirty buffer OR an unresolved external-change conflict: a
    // restored clean-but-conflicted tab (auto-reload off) holds its old buffer
    // and the Reload/Keep-mine choice only in memory/session, so closing it
    // blind would silently drop that choice.
    if (tab is DocumentTab &&
        (tab.doc.isDirty || tab.doc.hasExternalConflict)) {
      final ok = await _confirmDiscard(context, '"${tab.doc.title}"');
      if (!ok) return;
    }
    ws.closeAt(index);
  }

  // --- Drag & drop files ------------------------------------------------------

  Future<void> _onFilesDropped(
      DropDoneDetails detail, WorkspaceController ws) async {
    setState(() => _dragging = false);
    for (final dropped in detail.files) {
      final bookmark = dropped.extraAppleBookmark;
      var accessing = false;
      try {
        // Sandboxed macOS drops from outside the container need security-scoped
        // access via the bookmark desktop_drop attaches.
        if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
          accessing = await DesktopDrop.instance
              .startAccessingSecurityScopedResource(bookmark: bookmark);
        }
        final file = File(dropped.path);
        if (await file.exists()) {
          final content = await file.readAsString();
          // For a security-scoped (sandboxed, external) drop, don't track the
          // path: later unscoped dart:io save/watch would fail. Open it as an
          // untitled doc carrying the content + name instead.
          ws.openDocument(
            content,
            path: accessing ? null : file.absolute.path,
            displayName: dropped.name,
          );
        }
      } catch (_) {
        /* skip unreadable items */
      } finally {
        if (accessing && bookmark != null) {
          await DesktopDrop.instance
              .stopAccessingSecurityScopedResource(bookmark: bookmark);
        }
      }
    }
  }

  Widget _dropHint(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: Container(
        color: cs.primary.withValues(alpha: 0.08),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.primary, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.file_download_outlined, color: cs.primary),
              const SizedBox(width: 10),
              const Text('Drop Markdown files to open'),
            ],
          ),
        ),
      ),
    );
  }

  // --- Tab drag: reorder or tear off into a new window ------------------------

  void _onTabDragEnd(int index, DraggableDetails details) {
    if (details.wasAccepted) return; // dropped onto another tab → reordered
    final size = MediaQuery.sizeOf(context);
    final o = details.offset;
    const margin = 48.0;
    final outside = o.dx < -margin ||
        o.dy < -margin ||
        o.dx > size.width + margin ||
        o.dy > size.height + margin;
    if (outside) _tearOff(index);
  }

  /// Tear a tab off into its own standalone window. The in-memory content (and
  /// dirty state) is handed off via a temp file so unsaved edits aren't lost.
  /// Print previews are ephemeral and are not torn off.
  Future<void> _tearOff(int index) async {
    final ws = context.read<WorkspaceController>();
    if (index < 0 || index >= ws.tabs.length) return;
    final tab = ws.tabs[index];
    if (tab is! DocumentTab) return;
    final doc = tab.doc;
    final handoff = <String, dynamic>{
      'path': doc.filePath,
      'content': doc.currentMarkdown(),
      'dirty': doc.isDirty || doc.filePath == null,
      'name': doc.filePath == null ? doc.title : null,
    };
    // Write the handoff (which may contain unsaved draft content) to a private,
    // unpredictable temp directory rather than a world-readable path in /tmp.
    Directory? tmpDir;
    try {
      tmpDir = await Directory.systemTemp.createTemp('mdstudio_handoff_');
      final tmp = File('${tmpDir.path}${Platform.pathSeparator}handoff.json');
      await tmp.writeAsString(jsonEncode(handoff));
      await Process.start(
        Platform.resolvedExecutable,
        [SingleInstanceService.newWindowFlag, '--handoff', tmp.path],
        mode: ProcessStartMode.detached,
      );
      ws.closeAt(index);
    } catch (_) {
      // Spawn failed; clean up the temp dir and leave the tab in place.
      try {
        await tmpDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  void _onMenu(BuildContext context, WorkspaceController ws,
      DocumentController? active, String value) {
    switch (value) {
      case 'open':
        _open(context, ws);
        break;
      case 'new':
        ws.newDocument();
        break;
      case 'find':
        if (active != null) _openFind(active);
        break;
      case 'replace':
        if (active != null) _openFind(active, replace: true);
        break;
      case 'save':
        if (active != null) _save(context, active);
        break;
      case 'saveAs':
        if (active != null) _saveAs(context, active);
        break;
      case 'print':
        if (active != null) _print(context, active);
        break;
      case 'zoomIn':
        context.read<ZoomController>().zoomIn();
        break;
      case 'zoomOut':
        context.read<ZoomController>().zoomOut();
        break;
      case 'zoomReset':
        context.read<ZoomController>().reset();
        break;
      case 'checkUpdates':
        _checkUpdatesManually();
        break;
      case 'toggleUpdateCheck':
        final updates = context.read<UpdateController>();
        updates.setCheckOnStartup(!updates.checkOnStartup);
        break;
      case 'support':
        _support(context);
        break;
      case 'about':
        _about(context);
        break;
    }
  }

  /// Manual "Check for updates": unlike the quiet launch check, report the
  /// outcome either way.
  Future<void> _checkUpdatesManually() async {
    final updates = context.read<UpdateController>();
    final messenger = ScaffoldMessenger.of(context);
    if (updates.available != null) {
      _startUpdate(updates.available!);
      return;
    }
    final found = await updates.check(respectToggle: false);
    if (!mounted) return;
    if (found) {
      _startUpdate(updates.available!);
    } else {
      final version = (await PackageInfo.fromPlatform()).version;
      messenger.showSnackBar(SnackBar(
          content: Text('No update found — you are on $version '
              '(or the check could not reach GitHub).')));
    }
  }

  /// Walk the user through the one-click update. Installed desktop copies
  /// download the matching installer and hand it to the OS; anything else
  /// (portable, store, mobile, dev builds) goes to the download page.
  Future<void> _startUpdate(UpdateInfo info) async {
    final updates = context.read<UpdateController>();
    final ws = context.read<WorkspaceController>();
    final kind = updates.installKind;
    final oneClick = kind.canOneClick;
    // Only the MSI/Inno path exits and auto-relaunches, snapshotting the tabs
    // right before it — so a file-args window is restored there. The deb /
    // download-page paths keep running (or don't exit) and rely on the
    // auto-session, so they only restore when that's actually on (a plain
    // launch). Promise restore in the dialog accordingly.
    final autoRelaunch = kind == InstallKind.msi || kind == InstallKind.inno;
    final willRestore =
        autoRelaunch ? ws.willRestoreOnRelaunch : ws.sessionEnabled;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.system_update_alt_rounded),
        title: Text('Update to ${info.version}?'),
        content: Text(
          switch (kind) {
                InstallKind.msi ||
                InstallKind.inno =>
                  "Here's what happens: the update downloads, then Markdown "
                      'Studio closes, installs it in the background (no admin '
                      'prompt), and reopens. Takes a few seconds.',
                InstallKind.deb =>
                  'The package downloads and opens in your software installer; '
                      'the new version is used on the next launch.',
                InstallKind.other =>
                  'Your install type updates from the download page — the '
                      'right installer is one click there.',
              } +
              // Promise restore only when this update path actually brings the
              // current tabs back (see [willRestore]); otherwise tell the user
              // to save, since it would reopen to the previously saved session.
              (willRestore
                  ? ' Your open tabs and unsaved changes are restored when you '
                      'reopen.'
                  : ' After the update it reopens to your previously saved '
                      'session, so save any unsaved changes here first.'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Later')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(oneClick ? 'Update now' : 'Open download page')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    // From here on, always this State's context, re-checked after awaits.

    if (!oneClick) {
      final ok = await launchUrl(Uri.parse(info.downloadPageUrl),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not open a browser — visit '
                '${info.downloadPageUrl} to update.')));
      }
      return;
    }

    // The Windows install path exits and auto-relaunches. A restorable window
    // (plain or file-args) loses nothing — its tabs are snapshotted right
    // before the relaunch — so it needs no early prompt. Only a torn-off window
    // can't be restored, so confirm any unsaved work will be discarded before
    // we spend time downloading.
    final exitsForInstall = autoRelaunch;
    if (exitsForInstall && !ws.willRestoreOnRelaunch) {
      if (!await _prepareExit() || !mounted) return;
    }

    final progress = ValueNotifier<double>(-1);
    var cancelled = false;
    void Function()? abortDownload;
    // Only ever pop the progress dialog once — a failure AFTER it was
    // dismissed (e.g. the installer launch throws) must not pop again and
    // take the editor route with it.
    var progressOpen = true;
    void closeProgress() {
      if (progressOpen && mounted) {
        progressOpen = false;
        Navigator.of(context, rootNavigator: true).pop();
      }
      progressOpen = false;
    }

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Downloading update…'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) =>
              LinearProgressIndicator(value: v < 0 ? null : v),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              progressOpen = false;
              // Bite immediately, even mid-stall — don't wait for a chunk.
              abortDownload?.call();
              Navigator.pop(dialogContext);
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    final messenger = ScaffoldMessenger.of(context);
    try {
      final (url, name) = switch (kind) {
        InstallKind.msi => (info.msiUrl, 'markdown-studio-${info.version}.msi'),
        InstallKind.inno => (
            info.setupExeUrl,
            'markdown-studio-${info.version}-setup.exe'
          ),
        _ => (info.debUrl, 'markdown-studio-${info.version}.deb'),
      };
      final path = await updates.downloadInstaller(
          url, name, (v) => progress.value = v,
          isCancelled: () => cancelled,
          onAbortAvailable: (abort) => abortDownload = abort);
      if (cancelled) return;
      closeProgress();
      if (exitsForInstall) {
        // Snapshot the CURRENT tabs now that the download is done — the app
        // stayed alive through it, during which a watcher could have
        // auto-reloaded a clean tab or surfaced a conflict, so capture the
        // latest state. A restorable window snapshots (a file-args launch to
        // the one-shot relaunch store, a plain launch by flushing its session).
        if (ws.willRestoreOnRelaunch) {
          // If the snapshot can't be written (disk full), we can't keep the
          // "your tabs are restored" promise, so abort rather than relaunch
          // onto a stale session — even when nothing is dirty (a clean-tab
          // window wouldn't be caught by the discard prompt).
          if (!await ws.persistSessionForRelaunch()) {
            messenger.showSnackBar(const SnackBar(
                content: Text('Could not save your open tabs for the update — '
                    'free up disk space and try again.')));
            return;
          }
          if (!mounted) return;
        } else if (!await _prepareExit() || !mounted) {
          // Not restorable (torn-off): confirm discarding any unsaved work.
          return;
        }
        // Spawn first, release second: the wscript launcher only WAITS for this
        // process id, so starting it before teardown is safe, and it starts the
        // install only after the pid vanishes — file replacement can never race
        // shutdown. If the spawn throws, nothing has been released yet and the
        // editor stays fully functional (socket, watchers) for the error path.
        try {
          await updates.launchInstaller(path, kind);
        } catch (_) {
          // The installer helper failed to spawn: roll back the one-shot
          // relaunch snapshot so a later manual launch doesn't resurrect these
          // update-time tabs, then let the outer catch surface the error.
          await ws.clearRelaunchSnapshot();
          rethrow;
        }
        await _releaseResources();
        exit(0);
      } else {
        // The .deb / download-page paths keep running, so DON'T snapshot here:
        // a mid-update snapshot would freeze the session while later edits and
        // discards go untracked (a file-args launch has auto-persist off),
        // resurrecting stale state on the next launch. These paths rely on the
        // auto-session (a plain launch), matched by the dialog's restore copy.
        await updates.launchInstaller(path, kind);
        messenger.showSnackBar(SnackBar(
            content: Text('Installer opened — ${info.version} takes over '
                'on the next launch.')));
      }
    } on UpdateCancelled {
      // The user pressed Cancel; the partial download is already deleted.
    } catch (e) {
      if (cancelled) return; // aborted mid-stall: quiet, like any cancel
      closeProgress();
      messenger.showSnackBar(SnackBar(
          content: Text('Update failed ($e). '
              'Get it from markdownstudio.dev instead.')));
    }
  }

  /// Open the project's support (donation) page in the external browser.
  Future<void> _support(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await launchUrl(
      Uri.parse('https://venmo.com/u/thesaltykorean'),
      mode: LaunchMode.externalApplication,
    );
    if (!ok) {
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Could not open the browser — venmo.com/u/thesaltykorean')));
    }
  }

  /// Show About with the app's real version (read from the build metadata —
  /// a hardcoded string here once shipped stale).
  Future<void> _about(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'Markdown Studio',
      applicationVersion: info.version,
      applicationLegalese: 'A cross-platform Markdown viewer & WYSIWYG editor.'
          '\n\nMarkdown Studio is a formatting tool and does not provide '
          'legal advice. Documents it produces (including the Court Filing '
          'profile) are not guaranteed to meet any court\u2019s requirements '
          '\u2014 filing rules vary by jurisdiction; always check your local '
          'court\u2019s rules or consult a licensed attorney.',
    );
  }
}

enum _AssocChoice { associate, notNow, never }

/// Compact, icon-only Edit/Split/Raw/Preview toggle. Tooltips name each mode.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.doc});

  final DocumentController doc;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<EditorMode>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
      segments: [
        for (final m in EditorMode.values)
          ButtonSegment(
            value: m,
            icon: Icon(m.icon, size: 18),
            tooltip: m.label,
          ),
      ],
      selected: {doc.mode},
      onSelectionChanged: (s) => doc.setMode(s.first),
    );
  }
}

/// Horizontal, scrollable strip of open-document tabs plus a "new tab" button.
/// The tabs scroll by mouse wheel/trackpad, and left/right chevrons appear when
/// they overflow the available width.
class _TabStrip extends StatefulWidget {
  const _TabStrip({
    required this.workspace,
    required this.onClose,
    required this.onTabDragEnd,
  });

  final WorkspaceController workspace;
  final ValueChanged<int> onClose;
  final void Function(int index, DraggableDetails details) onTabDragEnd;

  @override
  State<_TabStrip> createState() => _TabStripState();
}

class _TabStripState extends State<_TabStrip> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final workspace = widget.workspace;
    final tabs = workspace.tabs;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      // Tabs flow left-to-right and wrap onto additional rows as they overflow
      // the width, rather than scrolling within a single row.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // New-tab button, left-aligned before the first tab.
          SizedBox(
            height: 36,
            child: IconButton(
              tooltip: 'New tab',
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add_rounded),
              onPressed: workspace.newDocument,
            ),
          ),
          for (var i = 0; i < tabs.length; i++)
            _draggableTab(context, workspace, tabs, i, cs),
          // Trailing drop target so a tab can be dropped after the last one.
          DragTarget<int>(
            onWillAcceptWithDetails: (d) => true,
            onAcceptWithDetails: (d) => workspace.reorder(d.data, tabs.length),
            builder: (context, candidate, rejected) => Container(
              width: 48,
              height: 36,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color:
                        candidate.isNotEmpty ? cs.primary : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _draggableTab(
    BuildContext context,
    WorkspaceController workspace,
    List<WorkspaceTab> tabs,
    int i,
    ColorScheme cs,
  ) {
    final tab = _Tab(
      tab: tabs[i],
      selected: i == workspace.activeIndex,
      onTap: () => workspace.select(i),
      onClose: () => widget.onClose(i),
    );
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != i,
      onAcceptWithDetails: (d) => workspace.reorder(d.data, i),
      builder: (context, candidate, rejected) {
        return SizedBox(
          height: 36,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: candidate.isNotEmpty ? cs.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Draggable<int>(
              data: i,
              feedback: Material(
                color: Colors.transparent,
                elevation: 6,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Container(
                    color: cs.surfaceContainerHigh,
                    child: tab,
                  ),
                ),
              ),
              childWhenDragging: Opacity(opacity: 0.3, child: tab),
              onDragEnd: (details) => widget.onTabDragEnd(i, details),
              child: tab,
            ),
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final WorkspaceTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final String title;
    final String tooltip;
    final bool dirty;
    final IconData? leading;
    switch (tab) {
      case DocumentTab(:final doc):
        title = doc.title;
        dirty = doc.isDirty;
        leading = null;
        final path = doc.filePath;
        tooltip = path != null
            ? '${doc.title}\n${p.dirname(path)}'
            : 'Unsaved — not yet saved to disk';
      case PrintPreviewTab(title: final previewTitle):
        title = previewTitle;
        dirty = false;
        leading = Icons.print_outlined;
        tooltip = 'Print preview — print the document again to refresh it';
    }
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 200),
          padding: const EdgeInsets.only(left: 12, right: 4),
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
              if (leading != null)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Icon(leading, size: 14, color: cs.onSurfaceVariant),
                ),
              if (dirty)
                Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Icon(Icons.circle, size: 7, color: cs.primary),
                ),
              Flexible(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? cs.onSurface : cs.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close_rounded),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
