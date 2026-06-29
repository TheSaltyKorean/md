import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Enforces a single primary instance on desktop and forwards file paths to it.
///
/// When the OS launches the app to open a `.md` file (double-click), a second
/// process starts. Instead of opening a second window, that process connects to
/// the already-running primary over a loopback socket, hands off the file
/// path(s), and exits — so the file opens as a new tab in the existing window.
///
/// A "torn-off" window is launched with `--new-window`, which bypasses this
/// mechanism so it runs as its own standalone window.
class SingleInstanceService {
  static const int _port = 47821; // loopback-only coordination port
  static const String newWindowFlag = '--new-window';

  ServerSocket? _server;
  void Function(List<String> paths)? _onPaths;

  bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Try to become the primary instance. Returns true if this process is now
  /// the primary (or single-instance isn't supported); false if another primary
  /// already owns the port (caller should [forward] and exit).
  Future<bool> tryBecomePrimary() async {
    if (!isSupported) return true;

    // Is a primary already listening?
    try {
      final probe = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _port,
        timeout: const Duration(milliseconds: 350),
      );
      probe.destroy();
      return false; // a primary exists
    } catch (_) {
      // No primary; try to claim the port.
    }

    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen(_handleClient);
      return true;
    } catch (_) {
      // Couldn't bind (race or port taken) — run standalone.
      return true;
    }
  }

  /// Register a callback invoked when another instance forwards file paths.
  void onPaths(void Function(List<String> paths) handler) => _onPaths = handler;

  void _handleClient(Socket client) {
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
        if (paths.isNotEmpty) _onPaths?.call(paths);
        client.destroy();
      },
      onError: (_) => client.destroy(),
      cancelOnError: true,
    );
  }

  /// Send file paths to the primary instance.
  Future<void> forward(List<String> paths) async {
    if (paths.isEmpty) return;
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
