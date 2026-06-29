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
        docs.add(OpenedDocument(path: file.path ?? file.name, content: content));
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

  /// Show a save dialog. On mobile the bytes are written by the picker; on
  /// desktop we write the returned path ourselves. Returns the path or null.
  Future<String?> saveAs(String content, {String? suggestedName}) async {
    final bytes = Uint8List.fromList(utf8.encode(content));
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Markdown file',
      fileName: suggestedName ?? 'untitled.md',
      type: FileType.custom,
      allowedExtensions: _extensions,
      bytes: bytes, // required for Android/iOS to actually write
    );
    if (path == null) return null;

    // On desktop, saveFile only returns a path and we must write it ourselves.
    // On mobile the bytes were already written and `path` may be a content URI,
    // so a failed write here is expected and harmless.
    try {
      await File(path).writeAsString(content);
    } catch (e) {
      debugPrint('desktop write skipped/failed (ok on mobile): $e');
    }
    return path;
  }
}
