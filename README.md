# Markdown Studio

A cross-platform **Markdown viewer and WYSIWYG editor** built with **Flutter** and
**Material 3**. Runs on **Linux, Windows, Android, and iOS** from a single
codebase, and is structured for submission to all the major app stores.

## Features

- **Three view modes** (switchable from the bar under the title):
  - **Edit** — block-style, Notion-like WYSIWYG editor (AppFlowy Editor) with
    slash-commands (`/`) and a selection toolbar.
  - **Split** — raw Markdown source with a **live rendered preview**
    (side-by-side on wide screens, stacked on mobile).
  - **Preview** — read-only rendered view.
- **Material Design 3** with **light, dark, and system** themes (persisted).
- **Multi-document tabs** — open many `.md` files at once; opening into a clean
  Untitled tab reuses it. Close tabs (with an unsaved-changes guard).
- **`.md` file association** — on Windows/Linux the app offers (once) to register
  itself as a Markdown handler; Android, iOS and macOS declare the association in
  their manifests, so the app appears as a `.md` opener.
- **File operations** — New, Open (multi-select), Save, Save As across all
  platforms.
- **Live reload of external changes** — the open file is watched on disk
  (desktop). An **auto-reload toggle** in the toolbar controls behaviour:
  - **On** (default): when the file changes (e.g. `git pull`, sync, another
    editor) and you have no unsaved edits, it reloads automatically. If you *do*
    have unsaved edits, a banner lets you **Reload** or **Keep mine**.
  - **Off**: your buffer is left untouched; a banner notes the file changed and
    you decide when to save (your version wins on save).
- **Print & PDF export** with a per-document **branding profile** system:
  - Named profiles (e.g. *Personal* vs *Work*).
  - Logo, font family, primary/text colours, header & footer text.
  - Page numbers, date, document title in header.
  - Classification label (e.g. `CONFIDENTIAL`) and a diagonal **watermark**.
  - Each document remembers which profile it uses; one profile is the default.

## Project layout

```
lib/
├── main.dart                     # Entry point, providers, SharedPreferences
├── app.dart                      # MaterialApp, themes, localization delegates
├── models/
│   ├── editor_mode.dart          # Edit / Split / Preview enum
│   └── print_profile.dart        # Branding profile model (+ seeded profiles)
├── state/
│   ├── theme_controller.dart     # Light/dark/system, persisted
│   └── document_controller.dart  # Syncs WYSIWYG <-> Markdown, dirty tracking
├── services/
│   ├── file_service.dart         # Open/save via file_picker + dart:io
│   ├── print_profile_service.dart# Profile CRUD + per-document association
│   ├── markdown_pdf_builder.dart # Markdown -> themeable PDF widgets
│   └── print_service.dart        # Fonts, header/footer/watermark, print/share
├── screens/
│   └── editor_screen.dart        # Toolbar + mode switching
├── theme/
│   └── app_theme.dart            # Material 3 light & dark ThemeData
└── widgets/
    ├── wysiwyg_view.dart         # AppFlowy editor host
    ├── split_view.dart           # Source + live preview
    ├── preview_view.dart         # Rendered Markdown (flutter_markdown_plus)
    ├── print_dialog.dart         # Profile picker + PDF preview + print/export
    └── print_profile_editor.dart # Create/edit a branding profile
```

> **Note on `flutter_markdown`:** Google discontinued the original
> `flutter_markdown` in 2025. This project uses the maintained successor,
> **`flutter_markdown_plus`**.

## Getting started

### 1. Install Flutter

Follow <https://docs.flutter.dev/get-started/install> for your OS and make sure
`flutter` is on your `PATH`. Verify with:

```bash
flutter --version
flutter doctor
```

> #### ⚠️ Flutter version: use 3.41.x (stable)
>
> This project is pinned to **Flutter 3.41.9** (see `.fvmrc`). Flutter **3.44+**
> added `onFocusReceived` to `TextInputClient`, which the current
> `appflowy_editor` (6.2.0) does not yet implement — building against 3.44 fails
> to compile the editor. `flutter analyze` passes but `flutter run`/`flutter
> build` will not, until AppFlowy ships a fix.
>
> The easiest way to pin is [FVM](https://fvm.app):
>
> ```bash
> dart pub global activate fvm
> fvm install 3.41.9
> fvm use 3.41.9
> fvm flutter run -d windows   # prefix flutter commands with `fvm`
> ```
>
> If you don't use FVM, simply switch your global Flutter to a 3.41.x stable
> (`flutter downgrade`, or `git checkout 3.41.9` in your Flutter SDK). Bump the
> pin once AppFlowy supports 3.44+. Verified working on **3.41.9 / Dart 3.11.5**
> (`flutter analyze` clean, `flutter test` green).

### 2. Native platform projects

The `android/`, `ios/`, `linux/`, `windows/`, and `macos/` folders are **already
included** in this repo (org `com.skmeridian`). Just fetch packages:

```bash
flutter pub get
```

If you ever need to regenerate them or add a platform, use the helper scripts
(`./tool/setup.sh` or `pwsh ./tool/setup.ps1`), or run directly:

```bash
flutter create --org com.skmeridian --project-name markdown_studio \
  --platforms=android,ios,linux,windows,macos .
```

### 3. Run it

```bash
flutter run -d windows      # or: linux, macos
flutter run -d <device-id>  # Android / iOS; list with: flutter devices
```

## Building release artifacts

| Platform | Command | Output |
| --- | --- | --- |
| Android (Play Store) | `flutter build appbundle --release` | `build/app/outputs/bundle/release/app-release.aab` |
| Android (sideload)   | `flutter build apk --release` | `build/app/outputs/flutter-apk/app-release.apk` |
| iOS (App Store)      | `flutter build ipa --release` | `build/ios/ipa/*.ipa` |
| Windows              | `flutter build windows --release` | `build/windows/x64/runner/Release/` |
| Linux                | `flutter build linux --release` | `build/linux/x64/release/bundle/` |
| macOS                | `flutter build macos --release` | `build/macos/Build/Products/Release/` |

## Continuous integration

`.github/workflows/ci.yml` runs on every push/PR: it analyzes + tests, then
builds **Android (APK + AAB)**, **Linux**, **Windows**, and **iOS/macOS**
(no-codesign) on their respective runners, uploading the artifacts. Per project
policy, a PR also runs a **Codex review loop and must get the all-clear before
it is merged** (see `CLAUDE.md`).

## App store submission notes

Set the version in `pubspec.yaml` (`version: <semver>+<buildNumber>`). The build
number must increase with every store upload.

### Google Play (Android)
1. Create a signing keystore and configure `android/key.properties` +
   `android/app/build.gradle` signing config (see Flutter's
   [Android deployment guide](https://docs.flutter.dev/deployment/android)).
2. `flutter build appbundle --release`.
3. Upload the `.aab` in the Play Console, complete the store listing, data-safety
   form, and content rating, then roll out to a track.

### Apple App Store (iOS)
1. Requires a Mac with Xcode and an Apple Developer account.
2. Set the bundle id and signing team in Xcode (`ios/Runner.xcworkspace`).
3. `flutter build ipa --release`, then upload with **Transporter** or
   `xcrun altool`/Xcode Organizer. Submit for review in App Store Connect.
   See [iOS deployment](https://docs.flutter.dev/deployment/ios).

### Microsoft Store (Windows)
- Package as MSIX. Add the [`msix`](https://pub.dev/packages/msix) dev dependency,
  configure it in `pubspec.yaml`, then `dart run msix:create` (or
  `:publish` to push to Partner Center). Alternatively distribute the raw
  `Release/` bundle or an installer.

### Linux app stores
- **Snap:** add a `snap/snapcraft.yaml` and run `snapcraft`; publish to the
  Snap Store.
- **Flatpak:** create a Flatpak manifest packaging the `bundle/` output for
  Flathub.
- See [Linux deployment](https://docs.flutter.dev/deployment/linux).

## License

Source-available under the **PolyForm Noncommercial License 1.0.0** (see
[`LICENSE.md`](LICENSE.md)). In short:

- ✅ **Free** for any **non-commercial** purpose (personal use, research,
  education, noncommercial organizations), including making changes and new
  works for those purposes.
- 💼 **Commercial / business use is not granted** by this license — contact the
  copyright holder for commercial terms.

This is a source-available license, **not** an OSI open-source license. Not
legal advice.

## Tests

```bash
flutter test
```

## Branding profiles (print)

Open **Print / Export PDF** (printer icon). Pick a profile, or:
- **+** to create a new profile (name, company, logo, font, colours, header/
  footer, page numbers, classification label, watermark, margin).
- **edit** to modify the selected profile.
- **Set as default** to use it for new/unassociated documents.
- **Use for this document** to bind the current file to a profile, so a company
  document always prints with company branding while personal notes use yours.

Two profiles ship by default: **Personal** and **Work** (the latter demonstrates
a `CONFIDENTIAL` watermark + footer). Edit or delete them freely.

Fonts are fetched from Google Fonts at print time and fall back to the built-in
PDF standard fonts when offline, so printing never fails for a missing typeface.
