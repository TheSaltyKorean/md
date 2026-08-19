# CLAUDE.md — Project guide & working rules

This file tells Claude Code (and any contributor) how to work in this repo.
It captures the project's conventions and the user's standing rules.

## What this is

**Markdown Studio** — a cross-platform Markdown **viewer + WYSIWYG editor** built
with **Flutter** and **Material 3**. Targets **Linux, Windows, Android, iOS**
(+ macOS), and is intended for submission to **all major app stores**.

The README is intentionally short (downloads + highlights) — keep it that
way. Full details live in `docs/DEVELOPMENT.md` (toolchain, layout, building)
and `docs/RELEASING.md` (release pipeline, signing, stores). Agreed-but-unbuilt
work is tracked in `docs/ROADMAP.md`. High level:

- Four view modes: **Edit** (AppFlowy block/Notion-style WYSIWYG), **Split**
  (source + live preview), **Raw** (full-width source), **Preview** (read-only
  render). Multi-document tabs with reorder + tear-off; find & replace in the
  source modes; a floating format toolbar.
- Material 3 with **light / dark / system** themes (persisted).
- File open/save across platforms; single-instance desktop app; `.md` file
  association; drag & drop.
- **Print + PDF export** in a **print-preview tab** (never a modal dialog —
  user rule), with a per-document **branding-profile** system (logo, fonts,
  colors, header/footer, page numbers, classification label + `CONFIDENTIAL`
  watermark, legal/manuscript layout). Selecting a profile for a saved
  document **binds it automatically** (edits/defaults never bind; unpin is
  final; bindings follow Save As). Seeded profiles: **Personal**, **Work**,
  and **Court Filing**. Legal mode: uniform 12pt body, continuous
  double-spaced rhythm, paragraphs/list items **flow across pages**; tall
  code blocks/quotes paginate and images cap to a page. The PDF renderer
  also supports a small inline-HTML subset (span fill-in blanks/labels, div
  alignment + flex rows, page-break directives) — see
  `docs/pdf-inline-html.md`.
- About reads the app version from build metadata (`package_info_plus`) —
  never hardcode a version string in UI. A "Support the project ❤" menu item
  opens https://venmo.com/u/thesaltykorean (also badged in the README).

## Standing rules (from the user — always follow)

1. **Open a PR and let CI pass before merging.** Branch protection requires a
   PR and the **`Analyze & test`** check — no direct pushes to `main`. Branch,
   commit, open a PR, wait for the checks, then merge with
   `gh pr merge <PR> --merge`.
   - **The Codex review loop was retired on 2026-08-19 at the owner's request.**
     It is no longer required and should not be reintroduced. Do not tag
     `@codex review`, and do not treat its absence as a gap.
   - `tool/codex-gate.sh` and `tool/codex-merge.sh` are left on disk but are
     unused. Nothing calls them.

2. **Prune branches after every merge.** As soon as a PR is merged, delete its
   remote branch (`git push origin --delete <branch>`, or `gh pr merge`'s
   `--delete-branch` flag) and run `git remote prune origin` (plus delete any
   local copy). Never delete a branch with an **open** PR or unmerged work —
   check `gh pr list` / `git branch -r --no-merged origin/main` first.
3. **Tooling lives under `C:\git`, not the `C:\` root.** e.g. the Flutter SDK is
   at `C:\git\flutter-sdk` (not `C:\flutter-sdk`). Keep build tooling out of the
   drive root.
4. **Cross-platform is non-negotiable.** Changes must keep Linux + Windows +
   Android + iOS building. Don't add platform-locked code without guards.
5. **Material Design + light & dark themes** must be preserved in any UI work.
6. **Printing must stay functional**, including the themeable header/footer and
   the per-document branding-profile system. The print preview opens in a
   **workspace tab**, not a modal dialog — keep it that way.
7. **Keep the README short** (badges, direct download links, highlights).
   Details belong in `docs/DEVELOPMENT.md` / `docs/RELEASING.md`.
8. **Never regenerate or lose the Android upload keystore.** It exists only
   in the owner's password manager (base64 text + password; GitHub secrets
   are write-only, not a backup). A new keystore changes the signing
   certificate and breaks in-place updates for every installed user.
   Cert SHA-256 ends in `…AE:CA:61:3F`.

## Distribution & publishing state (as of 2026-08-05)

- **Releases**: pushing a `v*` tag builds and publishes everything
  (`release.yml`); `workflow_dispatch` = dry run (no publish). Assets use
  stable versionless names so the README deep-links
  `releases/latest/download/…`. Latest: **v1.0.19**.
- **Windows**: MSI (WiX 5, permanent UpgradeCode — never change it),
  Inno setup.exe, portable zip. All unsigned; Store/winget are the trusted
  channels. WiX is pinned to 5.x (v6+ gates behind the OSMF EULA).
  **Per-user install since 1.0.9** (`Scope="perUser"` / Inno
  `PrivilegesRequired=lowest` → `%LocalAppData%\Programs\Markdown Studio`):
  no admin/UAC on install or update, so the in-app updater installs
  silently and in-place. A pre-1.0.9 per-machine Program Files copy is a
  different install context — uninstall it once when moving to 1.0.9+.
- **In-app updater** (since 1.0.5, fixed 1.0.7): quiet launch check against
  the latest GitHub release; an available update shows a toolbar button +
  launch snackbar. One click downloads the channel-matched installer
  (`InstallKind` msi/inno/deb/other) to a private temp dir and runs it via
  a generated wscript that waits for this process to exit, installs
  silently, and relaunches. Portable/store/mobile → download page.
- **winget**: **live and fully automated.** Identifier
  `TheSaltyKorean.MarkdownStudio` (CLA signed by the owner **as an
  individual**). First submission was
  [winget-pkgs#398219](https://github.com/microsoft/winget-pkgs/pull/398219)
  (1.0.17, merged 2026-07-20); 1.0.19 went through hands-off via
  [winget-pkgs#405700](https://github.com/microsoft/winget-pkgs/pull/405700)
  — moderator-approved and publish-pipeline-succeeded 2026-07-22. The
  `WINGET_TOKEN` secret (classic PAT, `public_repo`) is set and the
  `winget` job now runs for real on every tagged release, so no manual
  submission step is needed. Expect a lag between the release and
  `winget upgrade` seeing it — each version PR goes through winget-pkgs
  moderation.
- **Microsoft Store**: pipeline-ready (MSIX step gated on
  `MSIX_IDENTITY_NAME` / `MSIX_PUBLISHER` / `MSIX_PUBLISHER_DISPLAY_NAME`
  secrets; `PRIVACY.md` for the listing). **ON HOLD — do not publish or
  reserve the name**: the owner is deciding whether to publish personally
  ($19 individual account) or transfer the app to their business, whose
  **ISV Success** enrollment needs a published app. Waiting on the owner's
  Microsoft rep to confirm whether the consumer Store satisfies that
  milestone (the commercial marketplace doesn't take desktop apps). If the
  business route is chosen: paper an IP assignment/license from the owner
  first, and revisit the personal Venmo support link in that build.
- **Android**: releases carry a signed APK + AAB (keystore secrets set).
  Signing values reach Gradle via env vars, never a CI key.properties.
  Play listing not created yet; enroll in **Play App Signing** when it is.

## Known security limitation — re-check before related edits

`file_picker` is pinned to **10.x** (`^10.3.10`) with a **known Android CVE-22** (path
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
- `path_provider_foundation` is overridden to `>=2.4.1 <2.6.0` (2.6.0's
  native-assets implementation breaks macOS App Store uploads / crashes iOS).
- App / bundle id org: **`com.markdownstudio`** (→ `com.markdownstudio.markdown_studio`).

## Standard commands

```bash
fvm flutter pub get
fvm flutter analyze            # must be clean before commit
fvm flutter test               # must be green before commit
fvm flutter run -d windows     # or linux / macos / a device
```

Generate native platform folders (not committed by default — see README):

```bash
fvm flutter create --org com.markdownstudio --project-name markdown_studio \
  --platforms=android,ios,linux,windows,macos .
```

## Definition of done (every change)

- `flutter analyze` clean and `flutter test` green.
- Cross-platform preserved; Material + light/dark intact.
- Open a PR and let the **`Analyze & test`** check pass, **then** merge.
- After the merge: **delete the PR branch and prune** (`git remote prune
  origin`) — see standing rule 2.

## Architecture map

```
lib/
├── main.dart / app.dart              # entry, providers, launch args/handoff,
│                                     # MaterialApp + themes
├── models/        editor_mode (Edit/Split/Raw/Preview), print_profile
├── state/         theme_controller,
│                  document_controller (per-tab WYSIWYG<->Markdown sync, dirty),
│                  workspace_controller (tabs: documents + print previews)
├── services/      file_service, file_association_service, open_file_channel,
│                  single_instance_service, text_search,
│                  print_profile_service, markdown_pdf_builder, print_service
├── screens/       editor_screen (tab strip, toolbar, mode switching)
├── theme/         app_theme (M3 light/dark)
└── widgets/       wysiwyg_view, split_view, raw_view, source_pane, preview_view,
                   find_replace_bar, find_controller, format_toolbar,
                   print_preview_view, print_profile_editor
```
