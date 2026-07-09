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
  /// [directory] overrides the storage location (used by tests); production
  /// uses the platform app-support directory.
  FileSessionStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  File? _cached;

  Future<File> _file() async {
    final existing = _cached;
    if (existing != null) return existing;
    final dir = _directory ?? await getApplicationSupportDirectory();
    return _cached = File(p.join(dir.path, 'session.json'));
  }

  @override
  Future<String?> read() async {
    try {
      final f = await _file();
      if (await f.exists()) return await f.readAsString();
      // Crash recovery: rename isn't guaranteed atomic on every platform (it
      // can remove the destination before moving the temp into place), so a
      // crash mid-replace can leave the destination briefly missing while the
      // complete new data still sits in the temp file. Fall back to it rather
      // than report no session — that would drop the unsaved buffers the last
      // write was protecting.
      final tmp = File('${f.path}.tmp');
      if (await tmp.exists()) return await tmp.readAsString();
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String data) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    // Write-then-rename so a reader never sees a half-written file. rename is
    // not atomic on every platform; [read] falls back to this temp file if a
    // crash leaves the destination momentarily missing during the replace.
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
      // Drop any leftover temp too, so the crash-recovery fallback in [read]
      // can't resurrect a session the caller meant to clear.
      final tmp = File('${f.path}.tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {/* best effort */}
  }
}
