# Development guide

Toolchain, project layout, and building Markdown Studio from source.

## Toolchain

- **Flutter 3.41.9 (stable), pinned** — see `.fvmrc`. Flutter **3.44+ does
  not compile** this project yet: it added `TextInputClient.onFocusReceived`,
  which `appflowy_editor` 6.2.0 doesn't implement (`flutter analyze` passes
  but `flutter build` fails). Bump the pin only when AppFlowy supports 3.44+.
- Easiest pinning is [FVM](https://fvm.app):

  ```bash
  dart pub global activate fvm
  fvm install            # reads .fvmrc
  fvm flutter pub get
  fvm flutter run -d windows   # or linux / macos / a device id
  ```

  Without FVM, switch your global Flutter to 3.41.x
  (`flutter downgrade`, or `git checkout 3.41.9` in your Flutter SDK).
- `intl` is overridden to `0.20.2` (reconciles AppFlowy's `^0.19` with
  `flutter_localizations`); `path_provider_foundation` is pinned
  `>=2.4.1 <2.6.0` (2.6.0 breaks macOS App Store uploads / crashes iOS).
- Bundle id org: `com.markdownstudio` → `com.markdownstudio.markdown_studio`.

## Standard commands

```bash
fvm flutter pub get
fvm flutter analyze            # must be clean before commit
fvm flutter test               # must be green before commit
fvm flutter run -d linux
```

The native platform folders (`android/`, `ios/`, `linux/`, `windows/`,
`macos/`) are committed. To regenerate or add a platform:

```bash
fvm flutter create --org com.markdownstudio --project-name markdown_studio \
  --platforms=android,ios,linux,windows,macos .
```

(or use `./tool/setup.sh` / `pwsh ./tool/setup.ps1`).

## Project layout

```
lib/
├── main.dart                     # Entry point, providers, launch args, handoff
├── app.dart                      # MaterialApp, themes, localization delegates
├── models/
│   ├── editor_mode.dart          # Edit / Split / Raw / Preview enum
│   └── print_profile.dart        # Branding profile model (+ seeded profiles)
├── state/
│   ├── theme_controller.dart     # Light/dark/system, persisted
│   ├── document_controller.dart  # Per-tab doc: WYSIWYG <-> Markdown sync, dirty
│   └── workspace_controller.dart # Tabs (documents + print previews), auto-reload
├── services/
│   ├── file_service.dart         # Open/save via file_picker + dart:io
│   ├── file_association_service.dart # Register as .md handler (Windows/Linux)
│   ├── open_file_channel.dart    # OS open-file intents/URLs (Android/iOS/macOS)
│   ├── single_instance_service.dart  # One desktop instance; forwards open files
│   ├── text_search.dart          # Find/replace match engine (case/word/regex)
│   ├── print_profile_service.dart# Profile CRUD + per-document association
│   ├── markdown_pdf_builder.dart # Markdown (+ inline HTML) -> themed PDF widgets
│   └── print_service.dart        # Fonts, header/footer/watermark, print/share
├── screens/
│   └── editor_screen.dart        # Tab strip, toolbar, mode switching
├── theme/
│   └── app_theme.dart            # Material 3 light & dark ThemeData
└── widgets/
    ├── wysiwyg_view.dart         # AppFlowy editor host (Edit mode)
    ├── split_view.dart           # Source + live preview (Split mode)
    ├── raw_view.dart             # Full-width source editor (Raw mode)
    ├── source_pane.dart          # Shared monospace source TextField
    ├── preview_view.dart         # Rendered Markdown (flutter_markdown_plus)
    ├── find_replace_bar.dart     # Find & replace overlay for source views
    ├── find_controller.dart      # Opens/closes/focuses the find bar
    ├── format_toolbar.dart       # Floating, dockable formatting palette
    ├── print_preview_view.dart   # Print-preview tab: profiles + PDF preview
    └── print_profile_editor.dart # Create/edit a branding profile
```

> **Note on `flutter_markdown`:** Google discontinued the original package in
> 2025; this project uses the maintained successor, **`flutter_markdown_plus`**.

## Release builds

| Platform | Command | Output |
| --- | --- | --- |
| Android (Play Store) | `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |
| Android (sideload)   | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| iOS (App Store)      | `flutter build ipa --release` | `build/ios/ipa/*.ipa` |
| Windows              | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| Linux                | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| macOS                | `flutter build macos --release` | `build/macos/Build/Products/Release/` |

Published binaries are built by CI — see [RELEASING.md](RELEASING.md).

## Continuous integration

`.github/workflows/ci.yml` runs on every push/PR: analyze + tests, then
builds Android (APK + AAB), Linux, Windows, iOS (no-codesign) and macOS on
their respective runners; the Android, Linux and Windows jobs upload build
artifacts. Per project policy, every PR also runs a **Codex review loop and
must get the all-clear before merge** (see `CLAUDE.md`).

## Security & known limitations

- **`file_picker` Android CVE-22 (tracked, accepted):** the path-traversal
  fix is only in `file_picker` 11.x, which is incompatible with
  `appflowy_editor` 6.2.0 (still calls the v10 API). We're pinned to 10.x
  (`^10.3.10`) and will upgrade once AppFlowy supports v11. Android-only;
  requires a malicious content provider; mobile opens read bytes and don't
  trust the resolved path. Tracked in
  [#2](https://github.com/TheSaltyKorean/md/issues/2).
