# CLAUDE.md — Project guide & working rules

This file tells Claude Code (and any contributor) how to work in this repo.
It captures the project's conventions and the user's standing rules.

## What this is

**Markdown Studio** — a cross-platform Markdown **viewer + WYSIWYG editor** built
with **Flutter** and **Material 3**. Targets **Linux, Windows, Android, iOS**
(+ macOS), and is intended for submission to **all major app stores**.

See `README.md` for full feature/build/store docs. High level:

- Three view modes: **Edit** (AppFlowy block/Notion-style WYSIWYG), **Split**
  (source + live preview), **Preview** (read-only render).
- Material 3 with **light / dark / system** themes (persisted).
- File open/save across platforms.
- **Print + PDF export** with a per-document **branding-profile** system
  (logo, fonts, colors, header/footer, page numbers, classification label +
  `CONFIDENTIAL` watermark). Seeded profiles: **Personal** and **Work**.

## Standing rules (from the user — always follow)

1. **Codex review loop before every merge.** A PR must pass a Codex review loop
   *before* it is merged. Never merge a PR until Codex has given the all-clear.
   - Codex requires a **PR** to run (it cannot review a bare branch).
   - The loop: tag **`@codex`** in a PR comment → **poll the PR every ~5 minutes**
     for Codex's reply → address/resolve its feedback (push fixes, resolve
     threads) → tag `@codex` again → repeat **until Codex reports no issues**.
   - Only after the all-clear: merge.
2. **Tooling lives under `C:\git`, not the `C:\` root.** e.g. the Flutter SDK is
   at `C:\git\flutter-sdk` (not `C:\flutter-sdk`). Keep build tooling out of the
   drive root.
3. **Cross-platform is non-negotiable.** Changes must keep Linux + Windows +
   Android + iOS building. Don't add platform-locked code without guards.
4. **Material Design + light & dark themes** must be preserved in any UI work.
5. **Printing must stay functional**, including the themeable header/footer and
   the per-document branding-profile system.

## Known security limitation — re-check before related edits

`file_picker` is pinned to **10.3.x** with a **known Android CVE-22** (path
traversal), because `appflowy_editor` 6.2.0 still calls the file_picker v10 API
and the fix is only in v11. **Tracked in issue #2.**

> **Standing instruction:** whenever you touch `file_picker`, `appflowy_editor`,
> `pubspec.yaml` dependencies, or any file open/save flow, first check whether
> the fix can now be applied — i.e. has `appflowy_editor` released a version that
> uses the file_picker **v11** API? If yes, upgrade `file_picker` to >= 11.0.2,
> adapt the `FilePicker.platform` → static API change, verify the build, and
> **close issue #2**. If still blocked, leave the pin and the documentation in
> place.

## Toolchain

- **Flutter is pinned to 3.41.9** (see `.fvmrc`). Flutter **3.44+** is NOT yet
  supported: it added `TextInputClient.onFocusReceived`, which `appflowy_editor`
  6.2.0 doesn't implement, so 3.44 fails to compile (even though `flutter
  analyze` passes). Bump the pin only once AppFlowy supports 3.44+.
- SDK location: `C:\git\flutter-sdk`. Run via FVM, or put that `bin/` on `PATH`.
- `intl` is overridden to `0.20.2` in `pubspec.yaml` to reconcile AppFlowy
  (`intl ^0.19`) with `flutter_localizations` (`intl 0.20.2`).
- App / bundle id org: **`com.skmeridian`** (→ `com.skmeridian.markdown_studio`).

## Standard commands

```bash
fvm flutter pub get
fvm flutter analyze            # must be clean before commit
fvm flutter test               # must be green before commit
fvm flutter run -d windows     # or linux / macos / a device
```

Generate native platform folders (not committed by default — see README):

```bash
fvm flutter create --org com.skmeridian --project-name markdown_studio \
  --platforms=android,ios,linux,windows,macos .
```

## Definition of done (every change)

- `flutter analyze` clean and `flutter test` green.
- Cross-platform preserved; Material + light/dark intact.
- Open a PR, run the **Codex loop**, get the all-clear, **then** merge.

## Architecture map

```
lib/
├── main.dart / app.dart              # entry, providers, MaterialApp + themes
├── models/        editor_mode, print_profile
├── state/         theme_controller, document_controller (WYSIWYG<->Markdown sync)
├── services/      file_service, print_profile_service,
│                  markdown_pdf_builder, print_service
├── screens/       editor_screen
├── theme/         app_theme (M3 light/dark)
└── widgets/       wysiwyg_view, split_view, preview_view,
                   print_dialog, print_profile_editor
```
