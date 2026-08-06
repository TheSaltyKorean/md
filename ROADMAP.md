# Roadmap

Forward-looking work that is agreed on but not yet built. Past work lives in
the **Status log** in [`MEMORY.md`](MEMORY.md); this file is the other
direction — what we still owe.

Each item records the *why*, the concrete blockers, and a staged plan, so a
future session can pick it up without re-deriving the analysis. Items move to
the Status log when they ship.

---

## 1. Court filing templates for every state and federal court

**Status:** planned — not started. Blocked on engine gaps (see below).

Ship a browsable catalog of ready-made print profiles, one per court, so a
filer picks their court and gets a document that already conforms to that
court's local formatting rules. Today there is exactly one generic
**Court Filing** seeded profile; it encodes the *conventions most courts
share*, not any specific court's rules.

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
   `markdown_pdf_builder.dart`. Courts that require 13pt or 14pt, or a
   specific family (Century Schoolbook for SCOTUS; Times New Roman
   elsewhere), cannot be expressed.
5. **Seeded profiles are compiled-in constants.** `PrintProfile.seeds` is a
   `const` list of three, and profiles persist as one JSON list in
   `shared_preferences`. That mechanism does not scale to hundreds of
   templates — it needs a bundled read-only asset catalog, kept separate
   from the user's own editable profiles.

### Staged plan

- **Phase 0 — engine.** Close gaps 1–4: line numbering (`lineNumbers`,
  `lineNumberCount`, margin rules), per-edge margins, page size and body
  font size as profile fields. Each is independently useful and independently
  reviewable; ship them as separate PRs.
- **Phase 1 — catalog mechanism.** Bundled read-only template catalog (asset
  JSON, not `shared_preferences`), with browse/search by jurisdiction and
  "use this as a starting point" → copies into the user's profiles. Read-only
  so a rules update can replace a template without clobbering user edits.
- **Phase 2 — federal seed set.** Start with the tier that is most uniform
  and best documented: SCOTUS, the 13 circuits, and a first slice of
  district courts. Prove the catalog end-to-end on a tractable set.
- **Phase 3 — state high courts**, then intermediate appellate.
- **Phase 4 — trial courts**, accepting that coverage will be partial and
  county-level rules may never be complete.

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
