import 'dart:io';

import 'package:flutter/services.dart';

import '../state/workspace_controller.dart';

/// Receives "open this document" events that arrive as platform intents/URLs
/// rather than command-line arguments:
///  * **Android** — `ACTION_VIEW` intents (the native side reads the content
///    URI and passes the text content + display name);
///  * **iOS / macOS** — document open URLs (a readable file path).
///
/// Desktop Windows/Linux opens still come through argv (see `main`).
class OpenFileChannel {
  OpenFileChannel(this._workspace);

  static const MethodChannel _channel =
      MethodChannel('markdown_studio/open_file');

  final WorkspaceController _workspace;

  Future<void> init() async {
    _channel.setMethodCallHandler(_handle);
    // Pull any file the app was launched to open.
    try {
      final initial = await _channel.invokeMethod<dynamic>('getInitialFile');
      if (initial is Map) await _open(initial);
    } catch (_) {/* channel not implemented on this platform */}
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method == 'openFile' && call.arguments is Map) {
      await _open(call.arguments as Map);
    }
  }

  Future<void> _open(Map data) async {
    final content = data['content'] as String?;
    final path = data['path'] as String?;
    final name = data['name'] as String?;

    if (content != null) {
      // Android/iOS content isn't a re-writable dart:io path, so don't track
      // one — open the content with its display name.
      _workspace.openDocument(content, displayName: name);
      return;
    }
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          _workspace.openDocument(
            await file.readAsString(),
            path: file.absolute.path,
          );
        }
      } catch (_) {/* unreadable */}
    }
  }
}
