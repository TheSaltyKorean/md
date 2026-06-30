import 'package:flutter/material.dart';

/// The ways a document can be displayed.
enum EditorMode {
  /// Block-based "Notion-style" rich editor (AppFlowy Editor).
  wysiwyg,

  /// Raw Markdown source on the left, live rendered preview on the right.
  split,

  /// Full-width raw Markdown source editor, with no rendered preview.
  raw,

  /// Read-only rendered preview.
  preview;

  String get label => switch (this) {
        EditorMode.wysiwyg => 'Edit',
        EditorMode.split => 'Split',
        EditorMode.raw => 'Raw',
        EditorMode.preview => 'Preview',
      };

  IconData get icon => switch (this) {
        EditorMode.wysiwyg => Icons.edit_note_rounded,
        EditorMode.split => Icons.vertical_split_rounded,
        EditorMode.raw => Icons.code_rounded,
        EditorMode.preview => Icons.visibility_rounded,
      };

  /// True for modes that edit the raw Markdown source ([split] and [raw]) — as
  /// opposed to the block editor ([wysiwyg]) or read-only [preview].
  bool get isSource => this == EditorMode.split || this == EditorMode.raw;
}
