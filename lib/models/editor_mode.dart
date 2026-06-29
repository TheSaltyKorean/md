import 'package:flutter/material.dart';

/// The three ways a document can be displayed.
enum EditorMode {
  /// Block-based "Notion-style" rich editor (AppFlowy Editor).
  wysiwyg,

  /// Raw Markdown source on the left, live rendered preview on the right.
  split,

  /// Read-only rendered preview.
  preview;

  String get label => switch (this) {
        EditorMode.wysiwyg => 'Edit',
        EditorMode.split => 'Split',
        EditorMode.preview => 'Preview',
      };

  IconData get icon => switch (this) {
        EditorMode.wysiwyg => Icons.edit_note_rounded,
        EditorMode.split => Icons.vertical_split_rounded,
        EditorMode.preview => Icons.visibility_rounded,
      };
}
