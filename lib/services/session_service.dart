import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persists and restores the workspace session (open tabs, including unsaved
/// buffers) so the app reopens exactly where it left off — after an update's
/// silent relaunch, or any restart.
///
/// The store is a thin string read/write/clear abstraction so the
/// serialization logic in [WorkspaceController] stays unit-testable without
/// touching the filesystem (tests pass an in-memory implementation).
abstract class SessionStore {
  Future<String?> read();
  Future<void> write(String data);
  Future<void> clear();
}

/// A [SessionStore] backed by `session.json` in the app-support directory.
class FileSessionStore implements SessionStore {
  File? _cached;

  Future<File> _file() async {
    final existing = _cached;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _cached = File(p.join(dir.path, 'session.json'));
  }

  @override
  Future<String?> read() async {
    try {
      final f = await _file();
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String data) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    // Write-then-rename so a crash mid-write can't corrupt the session file
    // (a reader sees either the old complete file or the new complete one).
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {/* best effort */}
  }
}
