# MEMORY.md — Project memory & decision log

Durable context for this repo: the user's rules, key decisions, and their
rationale. Update this whenever a new rule or significant decision is made.

## User rules (authoritative)

| # | Rule | Why |
|---|------|-----|
| R1 | **Run a Codex review loop on a PR before every merge; only merge after Codex's all-clear.** | Codex acts as the gatekeeper reviewer. Merging without it skips required review. |
| R2 | **Codex loop mechanics:** tag `@codex` in PR comments, poll the PR ~every 5 min, resolve its feedback, re-tag, repeat until it reports no issues. Codex needs a PR to run. | This is how the Codex GitHub integration is driven on this repo. |
| R3 | **Build tooling goes under `C:\git`, never the `C:\` root** (e.g. Flutter SDK at `C:\git\flutter-sdk`). | Keep the drive root clean / tooling co-located with projects. |
| R4 | **Must remain cross-platform:** Linux, Windows, Android, iOS (+ macOS), for submission to all app stores. | Core product requirement. |
| R5 | **Material Design with light AND dark themes.** | Core product requirement. |
| R6 | **Printing is a first-class feature**, including themeable headers/footers and a **per-document branding-profile** system (logos, fonts, colors, classification labels, `CONFIDENTIAL` watermark). Different docs can use different profiles (e.g. work vs personal). Seeded profiles are **Personal**, **Work**, and **Court Filing** (keep public-facing names generic). | Explicit user requirement; work docs need branding + confidentiality, personal docs don't; court filings need strict legal formatting. |
| R7 | **Editor is block/Notion-style WYSIWYG** with an **optional split view** (source + live preview). | Explicit user requirement. |
| R8 | **Prune branches after every merge**: delete the merged PR's remote branch and `git remote prune origin`. Never delete branches with open PRs or unmerged work. | User instruction (2026-07-04); keeps the branch list to only live work. |
| R9 | **Print preview opens in a workspace tab, never a modal dialog.** | User instruction (2026-07-04); the preview must coexist with editing, not block it. |

## Key technical decisions

- **Framework:** Flutter (single codebase → all 4 platforms + app stores; Material 3 native). Chosen over React Native / .NET MAUI / Capacitor.
- **WYSIWYG:** `appflowy_editor` (block/Notion-style, Markdown round-trip via `markdownToDocument` / `documentToMarkdown`).
- **Preview rendering:** `flutter_markdown_plus` (the maintained successor after Google discontinued `flutter_markdown` in 2025).
- **Printing:** Markdown → themeable `pdf` widgets (`markdown_pdf_builder`) → `printing` for OS print/share; per-page header/footer/watermark; fonts via Google Fonts with built-in PDF-standard-font fallback (works offline).
- **State:** `provider` + `ChangeNotifier`; theme & print profiles persisted via `shared_preferences`.

## Toolchain constraints

- **Flutter pinned to 3.41.9** (`.fvmrc`). 3.44+ breaks AppFlowy (`TextInputClient.onFocusReceived` not implemented by `appflowy_editor` 6.2.0). Revisit when AppFlowy supports 3.44+.
- `intl` overridden to `0.20.2` (reconciles AppFlowy with `flutter_localizations`).
- `path_provider_foundation` overridden to `>=2.4.1 <2.6.0` (2.6.0 native-assets breaks macOS App Store uploads / crashes iOS).
- `file_picker` pinned to 10.3.x (Android CVE-22 accepted; fix needs v11, blocked on AppFlowy — issue #2).
- Org/bundle id base: `com.markdownstudio`.

## Status log

- 2026-06-28: Initial app built; `flutter analyze` clean, `flutter test` green on 3.41.9.
- 2026-06-29: SDK relocated to `C:\git\flutter-sdk`; native platform folders generated; first PR + Codex loop.
- 2026-06-29: Seeded "Work" profile genericised from a company name (public repo); kept `com.markdownstudio` bundle id.
- 2026-06-29: Added external-change handling — file watcher (desktop) + **auto-reload toggle**. On+clean = silent reload; On+dirty or Off = Reload/Keep-mine banner; save is last-write-wins by the user's choice.
- 2026-06-29: PR #1 ran a **9-round Codex loop** (findings 10→7→6→6→3→5→5→5→3, all fixed). One P1 accepted+documented: `file_picker` Android CVE-22 can't be cleared (fix is v11, AppFlowy 6.2.0 needs v10 API; 10.3.11 retracted) — tracked in issue #2. Merged into main per the user's "accept + document, merge now" decision.
- 2026-06-29: PR #4 fixed a `path_provider_foundation` P1 (pinned `>=2.4.1 <2.6.0`; 2.6.0 breaks macOS App Store uploads / crashes iOS) and added the Codex merge-gate hook. PRs #5–#7: Inter font + profile import/export + fast close; bundle id → `com.markdownstudio`; gate accepts head-SHA-bound clean-review comments.
- 2026-06-30: PR #8 (UI refinements) added the **Raw mode** (4 modes now), the **floating format toolbar**, compact mode toggle, and text-PDF export. PR #10 **removed the codex-gate CI enforcement** at the user's request — the Codex loop remains a standing rule by discipline. PRs #9/#11 print-dialog UX passes. PR #12 added **legal / court-filing print formatting** (legalMode, justify, line spacing, first-line indent, centred headings) + the **Court Filing** seeded profile + `docs/print-profiles.md` and `docs/ai-profile-authoring.md`.
- 2026-07-01: PR #13 fixed the WYSIWYG round-trip reformat-on-visit bug. PR #14 added **find & replace** (Ctrl/Cmd+F/H; case/whole-word/regex) over the Markdown source, with the pure `text_search.dart` engine.
- 2026-07-02: PR #15 added inline **`<span>` rendering to the PDF builder** (fill-in blanks, styled labels, transparent redaction) — a 10-round Codex loop hardened the parser (balanced-scan nesting, entity decoding, stray-tag stripping; known "split-span" limit documented).
- 2026-07-03: PR #16 added **`<div>` text-align and `display:flex` rows** to the PDF renderer (court captions, signature blocks). PR #17 (open): fix "widget won't fit" on tall blocks.
- 2026-07-04: New user rules **R8** (prune branches after every merge) and **R9** (print preview is a workspace tab, not a modal dialog). Implemented R9: `WorkspaceTab` (sealed: `DocumentTab` | `PrintPreviewTab`) in `workspace_controller.dart`; `PrintDialog` → embeddable `PrintPreviewView`; printing again refreshes the existing preview tab in place. Docs refreshed repo-wide (+ new `docs/pdf-inline-html.md`). Pruned 5 stale merged remote branches.
