import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// A document loaded from disk.
class OpenedDocument {
  const OpenedDocument({required this.path, required this.content});
  final String path;
  final String content;

  String get fileName => p.basename(path);
}

/// Cross-platform open / save of Markdown files using `file_picker` + dart:io.
class FileService {
  static const _extensions = ['md', 'markdown', 'mdown', 'mkd', 'txt'];

  /// Show an open dialog (multi-select) and return the chosen files' contents.
  /// Returns an empty list if the user cancelled.
  Future<List<OpenedDocument>> open() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Open Markdown file(s)',
      type: FileType.custom,
      allowedExtensions: _extensions,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return const [];

    final docs = <OpenedDocument>[];
    for (final file in result.files) {
      String? content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      }
      if (content != null) {
        docs.add(
            OpenedDocument(path: file.path ?? file.name, content: content));
      }
    }
    return docs;
  }

  /// Save [content] to [path]. Returns the path written, or null on failure.
  Future<String?> save(String content, String path) async {
    try {
      await File(path).writeAsString(content);
      return path;
    } catch (e) {
      debugPrint('save failed: $e');
      return null;
    }
  }

  /// Show a save dialog. On desktop we write the chosen path ourselves and
  /// return it as a re-writable [SaveResult.path]. On mobile the picker writes
  /// the bytes itself and may return a content URI that is *not* re-writable via
  /// dart:io, so we report success with a null path (the caller then treats the
  /// document as saved-without-a-tracked-path and re-prompts on the next save).
  Future<SaveResult> saveAs(String content, {String? suggestedName}) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Markdown file',
      fileName: suggestedName ?? 'untitled.md',
      type: FileType.custom,
      allowedExtensions: _extensions,
      bytes: bytes, // required for Android/iOS to actually write
    );
    if (path == null) return SaveResult.cancelled;

    if (Platform.isAndroid || Platform.isIOS) {
      // Bytes already written by the picker; the returned location isn't a
      // re-writable dart:io path, so don't track it as the document's path.
      return const SaveResult(saved: true, path: null);
    }

    try {
      await File(path).writeAsString(content);
      return SaveResult(saved: true, path: path);
    } catch (e) {
      debugPrint('save failed: $e');
      return SaveResult.cancelled;
    }
  }
}

/// Outcome of a Save As. On desktop [path] is a re-writable file path; on mobile
/// it is null even when [saved] is true (the picker owns the destination).
class SaveResult {
  const SaveResult({required this.saved, this.path});
  final bool saved;
  final String? path;
  static const SaveResult cancelled = SaveResult(saved: false);
}
