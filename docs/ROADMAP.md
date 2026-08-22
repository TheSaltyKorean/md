# Roadmap

Forward-looking work that is agreed on but not yet built. Past work lives in
the **Status log** in [`MEMORY.md`](https://github.com/TheSaltyKorean/md/blob/main/MEMORY.md); this file is the other
direction — what we still owe.

Each item records the *why*, the concrete blockers, and a staged plan, so a
future session can pick it up without re-deriving the analysis. Items move to
the Status log when they ship.

---

## 1. Court filing templates for every state and federal court

**Status:** planned — not started. Blocked on engine gaps (see below).

Ship a browsable catalog of ready-made print profiles, keyed by **court and
filing type** (a brief, a motion, and an appendix in the same court need not
share one format), so a filer picks their court and document type and gets a
document whose **formatting** matches that court's local rules. Today there is
exactly one generic **Court Filing** seeded profile; it encodes the
*conventions most courts share*, not any specific court's rules.

**This is formatting-only, and the scope line matters.** A `PrintProfile`
controls rendering — `PrintService` receives already-authored Markdown, so a
profile can set margins, spacing, fonts and page furniture, but it cannot
supply a caption block, a certificate of service, or enforce a page or word
limit. Those are *document content* concerns and need a separate capability
(boilerplate document templates + a limits check), tracked as item 2 below.
Until that exists, the catalog must be described to users as a formatting
starting point, never as compliance.

### Why this is worth doing

Local formatting rules are unforgiving and vary per court — margins, line
spacing, font family and size, whether numbered pleading paper is required,
caption layout, page or word limits, certificates of compliance. Getting them
wrong gets filings rejected. This is the highest-leverage thing the print
system could offer legal users, and it builds directly on the legal-mode work
already shipped (PRs #12, #16, #19–#21).

### Scope

Rough count of what "every court" means:

| Tier | Approx. count |
|---|---|
| Federal — district courts | 94 |
| Federal — courts of appeals | 13 |
| Federal — Supreme Court | 1 |
| Federal — bankruptcy + specialty (Fed. Cl., Tax, CIT, CAVC, …) | 90+ |
| State — high courts | 50 + DC + territories |
| State — intermediate appellate | ~40 |
| State — trial courts (rules often set county-by-county) | 50+ |

So **300+ templates** if taken literally, and the trial-court tier is not
even uniform within a state. This is not a single release.

### Engine gaps that block it

These are prerequisites — the templates cannot be correct without them. All
verified against the current code:

1. **Numbered pleading paper is not implemented.** No line-numbering support
   exists anywhere in `lib/` (grep for `lineNumber`/`pleading` finds only
   comments). California and several other states require 28 numbered lines
   with vertical margin rules. Without this, an entire tier of templates is
   impossible, not merely approximate.
2. **Page size is not part of a profile.** It lives as preview UI state in
   `print_preview_view.dart` (`_previewFormat`, defaulting to **A4**). US
   courts mandate Letter, some filings Legal. A court template that cannot
   pin its own page size is wrong the moment it is opened.
3. **Margins are a single uniform value.** `PrintProfile.marginCm` is one
   number applied to all edges. Courts routinely specify per-edge margins
   (e.g. 1" top/bottom/right with a wider left edge for binding).
4. **No font-size field on the profile.** `legalMode` hardcodes 12pt in
   `markdown_pdf_builder.dart`. Courts that require 13pt or 14pt cannot be
   expressed.
5. **The required font families are not available.**
   `PrintService.availableFonts` is seven Google families (Roboto, Inter,
   Lato, Open Sans, Montserrat, Merriweather, Noto Serif) with a Roboto
   fallback. **Times New Roman** — the most commonly mandated family — and
   **Century Schoolbook** (SCOTUS) are both absent, so those templates would
   silently fall back to a non-conforming face. This one is not just a
   missing field: it needs licensed or metric-compatible substitutes
   (e.g. Liberation Serif / TeX Gyre Schola) embedded in the PDF, plus a
   decision about shipping font binaries and their licences.
6. **Seeded profiles are compiled-in constants.** `PrintProfile.seeds` is a
   `const` list of three, and profiles persist as one JSON list in
   `shared_preferences`. That mechanism does not scale to hundreds of
   templates — it needs a bundled read-only asset catalog, kept separate
   from the user's own editable profiles.

### Staged plan

- **Phase 0 — engine.** Close gaps 1–5: line numbering (`lineNumbers`,
  `lineNumberCount`, margin rules), per-edge margins, page size and body
  font size as profile fields, and the court-required font families with
  embedding. Each is independently useful and independently reviewable; ship
  them as separate PRs. **Gap 5 gates Phase 2** — SCOTUS and most federal
  templates are unshippable until a conforming face is available, so it is
  not optional cleanup.
- **Phase 1 — catalog mechanism.** Bundled read-only template catalog (asset
  JSON, not `shared_preferences`), entries keyed by **court + filing type**
  so a court can carry multiple profiles/skeletons, with browse/search by
  jurisdiction and "use this as a starting point" → copies into the user's
  profiles. Read-only so a rules update can replace a template without
  clobbering user edits.
  **Copies must carry their origin** — source template id + version + the
  `lastVerified` they were taken from — because a bundled rules update
  replaces only the catalog entry, leaving already-copied profiles (including
  ones bound to live documents) silently stale. That provenance is what makes
  a reconciliation flow possible: on catalog update, flag bound documents
  whose copy is behind and offer a diff/re-pull. Without it a current
  `lastVerified` on the catalog is decoration, not a safeguard.
- **Phase 2 — federal seed set.** Start with the tier that is most uniform
  and best documented: SCOTUS and the 13 circuits. Prove the catalog
  end-to-end on a tractable set.
- **Phase 3 — remaining federal tiers.** The 94 district courts (local rules
  and standing orders vary per district), then bankruptcy and the specialty
  courts (Fed. Cl., Tax, CIT, CAVC).
- **Phase 4 — state courts.** High courts first, then intermediate appellate.
- **Phase 5 — trial courts**, accepting that coverage will be partial and
  county-level rules may never be complete.

### Completion criterion

"Every state and federal court" is the **direction**, not a shippable
definition of done — Phase 5 openly accepts coverage that may never be
complete, so treating the whole item as one deliverable would leave it
permanently open. Split it instead:

- **Finite, shippable:** Phases 0–2 (engine + catalog + the appellate federal
  tier: SCOTUS and the 13 circuits). That is a bounded set with well
  documented rules, and it is what moves to the Status log when it ships.
- **Ongoing, never "done":** Phases 3–5 are continuing coverage work, tracked
  by jurisdictions-covered rather than completion. Ship them incrementally;
  do not gate anything on finishing them.

Every tier in the Scope table maps to exactly one phase: appellate federal →
Phase 2, district + bankruptcy/specialty → Phase 3, state appellate → Phase 4,
trial → Phase 5. Nothing in that table is unassigned.

### Open questions to settle before Phase 1

- **Provenance and staleness.** Local rules change. A template labelled with a
  real court implies it is current. Each template needs a source citation
  (which local rule / standing order) and a `lastVerified` date surfaced in
  the UI, plus a plan for who re-verifies and how often. Without this the
  catalog decays silently into wrong-but-confident.
- **Liability framing.** The repo already disclaims legal advice in About,
  README and docs (PR #35/#36). Named-court templates raise that stakes:
  the disclaimer should be restated at point of use, and templates should be
  described as a formatting starting point that the filer must check against
  current local rules — never as compliance.
- **Sourcing.** Where do the rules come from, and is transcribing them into
  templates something we can do at volume and keep accurate? Realistically
  this gates how far past Phase 2 the item can go.
- **Contribution path.** Community-submitted templates would scale coverage
  far better than doing all 300+ in-house, but need a review process — this
  is exactly the content where an unreviewed wrong answer causes harm.

---

## 2. Document templates and filing checks (content, not formatting)

**Status:** planned — not started. Prerequisite for the *compliance* half of
item 1; independent of it otherwise.

Item 1 can only ever deliver **formatting**. The parts of a court filing that
a `PrintProfile` structurally cannot supply need a second capability:

- **Boilerplate document templates** — a starting Markdown document, not a
  render recipe: caption block, parties, case-number field, signature block,
  certificate of service, proof-of-service. Today the user must author all of
  this by hand; the existing `<div>` flex/align support in the PDF builder
  (PRs #16, #19) is what makes such captions renderable, but nothing
  *generates* them.
- **Filing checks** — page and word limits are the common hard constraints,
  and they are verifiable mechanically. A pre-filing check ("this brief is
  31 pages; the limit for this court is 30") is a genuinely useful,
  bounded feature and does not require legal judgement.

Pairs naturally with item 1's catalog: a court + filing-type entry would carry
*both* a print profile and a document skeleton, so "pick your court and
filing type" yields a formatted document that already has the right
scaffolding. Until this ships, item 1's catalog is described as
formatting-only.
