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
| R6 | **Printing is a first-class feature**, including themeable headers/footers and a **per-document branding-profile** system (logos, fonts, colors, classification labels, `CONFIDENTIAL` watermark). Different docs can use different profiles (e.g. work vs personal). Seeded profiles are **Personal** and **Work** (keep public-facing names generic). | Explicit user requirement; work docs need branding + confidentiality, personal docs don't. |
| R7 | **Editor is block/Notion-style WYSIWYG** with an **optional split view** (source + live preview). | Explicit user requirement. |

## Key technical decisions

- **Framework:** Flutter (single codebase → all 4 platforms + app stores; Material 3 native). Chosen over React Native / .NET MAUI / Capacitor.
- **WYSIWYG:** `appflowy_editor` (block/Notion-style, Markdown round-trip via `markdownToDocument` / `documentToMarkdown`).
- **Preview rendering:** `flutter_markdown_plus` (the maintained successor after Google discontinued `flutter_markdown` in 2025).
- **Printing:** Markdown → themeable `pdf` widgets (`markdown_pdf_builder`) → `printing` for OS print/share; per-page header/footer/watermark; fonts via Google Fonts with built-in PDF-standard-font fallback (works offline).
- **State:** `provider` + `ChangeNotifier`; theme & print profiles persisted via `shared_preferences`.

## Toolchain constraints

- **Flutter pinned to 3.41.9** (`.fvmrc`). 3.44+ breaks AppFlowy (`TextInputClient.onFocusReceived` not implemented by `appflowy_editor` 6.2.0). Revisit when AppFlowy supports 3.44+.
- `intl` overridden to `0.20.2` (reconciles AppFlowy with `flutter_localizations`).
- Org/bundle id base: `com.skmeridian`.

## Status log

- 2026-06-28: Initial app built; `flutter analyze` clean, `flutter test` green on 3.41.9.
- 2026-06-29: SDK relocated to `C:\git\flutter-sdk`; native platform folders generated; first PR + Codex loop.
- 2026-06-29: Seeded "Work" profile genericised from a company name (public repo); kept `com.skmeridian` bundle id.
- 2026-06-29: Added external-change handling — file watcher (desktop) + **auto-reload toggle**. On+clean = silent reload; On+dirty or Off = Reload/Keep-mine banner; save is last-write-wins by the user's choice.
- 2026-06-29: PR #1 ran a **9-round Codex loop** (findings 10→7→6→6→3→5→5→5→3, all fixed). One P1 accepted+documented: `file_picker` Android CVE-22 can't be cleared (fix is v11, AppFlowy 6.2.0 needs v10 API; 10.3.11 retracted) — tracked in issue #2. Merged into main per the user's "accept + document, merge now" decision.
