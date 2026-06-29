import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Enforces a single primary instance on desktop and forwards file paths to it.
///
/// When the OS launches the app to open a `.md` file (double-click), a second
/// process starts. Instead of opening a second window, that process connects to
/// the already-running primary over a loopback socket, hands off the file
/// path(s) — or an empty "focus" message when launched without arguments — and
/// exits, so the existing window is reused and brought to the front.
///
/// A handshake greeting proves the listener is actually Markdown Studio (and not
/// some unrelated service that happens to hold the port). A "torn-off" window is
/// launched with `--new-window`, which bypasses this mechanism entirely.
class SingleInstanceService {
  static const int _port = 47821; // loopback-only coordination port
  static const String newWindowFlag = '--new-window';
  static const String _magic = 'MARKDOWN_STUDIO_V1';

  ServerSocket? _server;
  void Function(List<String> paths)? _onPaths;

  bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Try to become the primary instance. Returns true if this process is now
  /// the primary (or single-instance isn't supported); false if a verified
  /// primary already owns the port (caller should [forward] and exit).
  Future<bool> tryBecomePrimary() async {
    if (!isSupported) return true;

    // Only defer to an existing instance that completes our handshake.
    if (await _verifiedPrimaryExists()) return false;

    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen(_handleClient);
      return true;
    } catch (_) {
      // Port held by a foreign service (no handshake) — run standalone.
      return true;
    }
  }

  Future<bool> _verifiedPrimaryExists() async {
    Socket? probe;
    try {
      probe = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 350),
      );
      final firstChunk =
          await probe.first.timeout(const Duration(milliseconds: 500));
      return utf8.decode(firstChunk, allowMalformed: true).contains(_magic);
    } catch (_) {
      return false; // nothing listening, or not our app
    } finally {
      probe?.destroy();
    }
  }

  /// Register a callback invoked when another instance forwards file paths (an
  /// empty list means "just focus the window").
  void onPaths(void Function(List<String> paths) handler) => _onPaths = handler;

  void _handleClient(Socket client) {
    // Greet first so a probing instance can verify this is Markdown Studio.
    client.write('$_magic\n');
    final bytes = <int>[];
    client.listen(
      bytes.addAll,
      onDone: () {
        final text = utf8.decode(bytes, allowMalformed: true);
        final paths = text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        _onPaths?.call(paths); // notify even when empty (focus request)
        client.destroy();
      },
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  /// Send file paths to the primary instance. An empty list is a focus request.
  Future<void> forward(List<String> paths) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 350),
      );
      socket.write(paths.join('\n'));
      await socket.flush();
      await socket.close();
    } catch (_) {
      // Primary went away between probe and send; nothing else to do.
    }
  }
}
