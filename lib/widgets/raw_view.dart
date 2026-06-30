import 'package:flutter/material.dart';

import '../state/document_controller.dart';
import 'source_pane.dart';

/// Full-width raw Markdown source editor — like the [SplitView] source pane but
/// with no rendered preview. For editing the literal Markdown text directly.
///
/// Named `RawSourceView` (not `RawView`) to avoid clashing with Flutter's own
/// `RawView` widget.
class RawSourceView extends StatelessWidget {
  const RawSourceView({super.key, required this.controller});

  final DocumentController controller;

  @override
  Widget build(BuildContext context) {
    return SourcePane(controller: controller);
  }
}
