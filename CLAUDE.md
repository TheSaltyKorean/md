# CLAUDE.md — Project guide & working rules

This file tells Claude Code (and any contributor) how to work in this repo.
It captures the project's conventions and the user's standing rules.

## What this is

**Markdown Studio** — a cross-platform Markdown **viewer + WYSIWYG editor** built
with **Flutter** and **Material 3**. Targets **Linux, Windows, Android, iOS**
(+ macOS), and is intended for submission to **all major app stores**.

See `README.md` for full feature/build/store docs. High level:

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
  watermark, legal/manuscript layout). Seeded profiles: **Personal**, **Work**,
  and **Court Filing**. The PDF renderer also supports a small inline-HTML
  subset (span fill-in blanks/labels, div alignment + flex rows) — see
  `docs/pdf-inline-html.md`.

## Standing rules (from the user — always follow)

1. **Codex review loop before every merge — mandatory, never skip.** A PR must
   pass a Codex review loop *before* it is merged. Never merge until Codex has
   given a literal all-clear (or the user has explicitly accepted open findings —
   see below). This is now enforced by **discipline, not machinery**: the
   `codex-gate` CI check and the local PreToolUse hook have been removed at the
   user's request. The rule still stands — do not treat the absence of a gate as
   permission to skip the loop.
   - Codex requires a **PR** to run (it cannot review a bare branch). So: branch,
     commit, open a PR.
   - **The loop:** tag **`@codex review`** in a PR comment → **poll the PR every
     ~5 minutes** → address/resolve its feedback (push fixes) → tag
     `@codex review` again on the new head → repeat **until Codex signals no
     issues** (see the all-clear definition below).
   - **"All-clear" means Codex gave a clean review on the current head.** Codex
     signals this in one of two ways: a literal 👍 (`+1`) reaction on the
     `@codex review` request, **or** a clean-review *comment* (e.g. "Codex
     Review: Didn't find any major issues") whose **"Reviewed commit:"** SHA is
     the current head. A Codex *review* (even a `COMMENTED` one) with open
     findings is NOT an all-clear. `tool/codex-gate.sh <PR>` is kept as a
     **convenience checker** — it prints `GREEN` only on a genuine all-clear
     bound to the head; use it to confirm before merging. Report honestly — e.g.
     "merged with N accepted findings", never "all-clear", when findings remain.
   - The all-clear = a **`@codex review` request newer than the PR head commit**,
     with no later findings, **and** either (a) a literal 👍 (`+1`) reaction from
     the Codex bot on that request, or (b) a Codex-bot clean-review comment
     ("…find any major issues…") that names the **current head SHA** in its
     "Reviewed commit:" line. Path (b) binds to the exact head SHA; only the
     Codex bot can author such a comment.
   - **Merging:** once all-clear, merge with `gh pr merge <PR> --merge` (or
     `bash tool/codex-merge.sh <PR>`, which re-checks the all-clear first).
     Branch protection still requires the **`Analyze & test`** check and a PR
     (no direct pushes to `main`), so let CI pass before merging.
   - **Accepted findings:** if the user *explicitly* decides to merge with an
     open finding, record that decision on the PR, then merge — and say so
     honestly ("merged with N accepted findings"). Never accept findings without
     explicit user approval, and never re-review only part of a change — re-run
     Codex on the **final** head before merge so nothing slips through
     unreviewed (this exact gap shipped a P1 once; don't repeat it).
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
- Open a PR, run the **Codex loop**, get the all-clear, **then** merge.
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
