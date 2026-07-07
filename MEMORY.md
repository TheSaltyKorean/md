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
| R10 | **Resolve Codex review threads as their fixes land** (GitHub "resolve conversation"), every round. | User instruction (2026-07-05); addressed comments must not dangle. |
| R11 | **Microsoft Store publishing is ON HOLD** — don't reserve the name or publish. Owner may transfer the app to their business (ISV Success program needs a published app; a free app qualifies per their Microsoft rep); awaiting rep's answer on whether the consumer Store counts. If transferred: IP assignment/license first, and revisit the personal Venmo link. | User decision (2026-07-06). |
| R12 | **Never lose/regenerate the Android upload keystore** (password manager only; cert SHA-256 …AE:CA:61:3F). | A new keystore breaks in-place updates for all installed users. |

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
- `file_picker` pinned to 10.x (`^10.3.10`) (Android CVE-22 accepted; fix needs v11, blocked on AppFlowy — issue #2).
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
- 2026-07-05: PR #19 **legal print polish**: legalMode blocks share one spaced rhythm (block gap = in-paragraph leading), **page-break directives** (`page-break-before/after:always`, `break-*:page`, `!important` ok; bare top-level div/hr only; visible elements break *and* render), literal `<br>` renders as a line break in headings/prose/span labels (3-round Codex loop).
- 2026-07-05: PR #20 **uniform 12pt legal body** via `_bodySize` (legal 12pt / non-legal 11pt): body text, div default (legal 12 / non-legal 10), list markers, blank baselines, and the block-gap rhythm all derive from it (clean first-round Codex).
- 2026-07-05: PR #21 **legal-mode flowing pagination**: body paragraphs/list items page-span (`TextOverflow.span`; pdf 3.12 `SingleChildWidget` delegates spanning), lists flattened one-widget-per-item with inline markers, gap as sibling `_FlowGap` trimmed at doc end/before breaks. Codex round 2 raised a **false-positive P1** ("String has no operator *") — rebutted with the dart:core API doc; round 3 clean. Note: open PR #17 (tall code/image/quote blocks) overlaps and needs a rebase.
- 2026-07-05: Linux desktop build verified on this machine (toolchain: clang/ninja/GTK installed; Flutter 3.41.9 SDK local). Removed unused `cupertino_icons` dependency (template bloat); docs synced with the three legal-print PRs.
- 2026-07-05: PR #22: **profiles auto-remembered per document** (selection = association; edits/defaults never bind; unpin is final; bindings follow Save As) + docs-consistency audit + cupertino_icons removal (3-round Codex loop).
- 2026-07-05: Added tag-triggered **`release.yml`**: pushing `v*` builds Android APK/AAB, Linux tar.gz, Windows zip, macOS zip, and an unsigned iOS `.ipa` on GitHub runners, then publishes a GitHub Release with install notes; README gained a **Download & install** section. Windows binaries come from the `windows-latest` runner (no PowerShell bridge to the Windows box from this Linux session).
- 2026-07-05: **v1.0.1 released** (PRs #23/#24, multi-round Codex loops): WiX **MSI** (permanent UpgradeCode; WiX pinned 5.x — v6+ gates behind the OSMF EULA), Inno **setup.exe**, Linux **.deb** (dual markdown MIME, glibc/libstdc++ dependency floor, built on ubuntu-22.04), stable versionless asset names + README direct links, `workflow_dispatch` **dry-run mode** (publish gated to tag *pushes* only), release perms hardened (`contents: write` on publish job only), Android signing via env vars (never CI key.properties — Properties.load mangles backslashes). **Keystore saga**: first keystore's documented key password was wrong (PKCS12 ignores `-keypass`) — regenerated with a single password; lives only in the owner's password manager (R12).
- 2026-07-05: README slimmed ~340→~80 lines (details moved to `docs/DEVELOPMENT.md` + `docs/RELEASING.md`); retroactively resolved 35 dangling Codex threads across PRs #18–24 → rule **R10**.
- 2026-07-06: PR #25 (supersedes stale #17, closed): tall **code blocks/quotes paginate** (per-line / per-child Columns), **images cap** to page height (`maxImageHeight`, scaleDown — never upscale); `.wixpdb` no longer ships. PR #26 (**v1.0.2**): About reads the real version via `package_info_plus` (hardcoded '1.0.0' had shipped stale in v1.0.1 — user-reported), in-app **"Support the project ❤"** Venmo link, **winget auto-update job** (gated on `WINGET_TOKEN` + upstream-existence probe), **Store MSIX step** (gated on 3 `MSIX_*` secrets; 4-part version carries the build number), `PRIVACY.md`.
- 2026-07-06: **winget initial submission** for 1.0.1: microsoft/winget-pkgs#398219 (manifests hand-authored; ProductCode/SHA extracted with msitools; Microsoft CLA signed by the owner **as an individual**). **Store publishing ON HOLD** (R11) pending the Microsoft rep's ISV-Success storefront answer; owner's business is ISV-Success-enrolled and looking for an app to publish — Markdown Studio is the candidate.
- 2026-07-07: **markdownstudio.dev live** on GitHub Pages (Cloudflare DNS, apex DNS-only/grey-cloud — REQUIRED for GitHub cert renewal; www proxied at owner's choice). Debugging lessons: an apex CNAME+A conflict blocks Let's Encrypt issuance, and a stuck never-started cert state is reset only by remove+re-add of the custom domain (two PR cycles: docs/CNAME delete then restore). Landing page carries SEO (SoftwareApplication/FAQPage JSON-LD, OG cards, sitemap with the Jekyll-rendered doc guides, Google verification tag) + IndexNow key for Bing pings. Repo topics/description/homepage set.
- 2026-07-07: **v1.0.3 released** (PRs #35/#36): document zoom (Ctrl +/-/0, Ctrl+wheel, persisted, composes with OS accessibility scale, inert on print tabs); printed PDFs render document images (https URLs pre-fetched with 20MB/image + 100MB/doc caps, 4-worker pool, 45s doc budget, cancelable deadlines, https-only incl. redirects, socket teardown on every reject path — an 8-round Codex loop hardened all of it); .md-association self-heal (installed copies reclaim from stale dev-build registrations, PR #28); legal disclaimers in About/README/docs (formatting tool, not legal advice). PRIVACY.md discloses both print-time request types (fonts + document image URLs).
