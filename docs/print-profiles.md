# Print & branding profiles (templates)

A **print profile** — sometimes called a *branding profile* or *template* — is a
reusable recipe that controls how a document looks when you **print** it or
**export it to PDF**: fonts, colours, logo, header/footer, page numbering,
watermark, and body-layout rules like justification, line spacing and first-line
indent.

Profiles are plain **JSON**, so you can create them three ways:

1. **In the app** — the visual profile editor (no JSON required).
2. **Import a JSON file** someone shared with you (or that you exported).
3. **Hand the spec to an AI** and import the JSON it produces — see
   [AI profile authoring](ai-profile-authoring.md) for a copy-paste prompt.

Each document remembers which profile it uses, and one profile is the app-wide
**default** for new or unassigned documents. So a company report can always print
with company branding while your personal notes use a plain profile.

Two profiles ship built in — **Personal** and **Work** — plus a **Court Filing**
profile that demonstrates the legal-formatting options (12pt body, double
spacing, justified body, 0.5″ first-line indent, centred captions, monochrome
output, text flowing continuously across pages).

## Why this exists

This feature grew out of a real workflow. If you draft with AI, you're constantly
moving between **Markdown and PDF** — AI assistants read, write, and reason over
Markdown far more efficiently than PDFs, but the world wants a finished PDF. So
the natural loop is: **keep the source in Markdown, let the AI do the work, and
render a properly formatted PDF at the end.**

The formatting is where it gets specific. As a **pro se litigant**, court
documents have to follow strict rules — double spacing, a serif face, justified
or specific alignment, first-line indents, one-inch margins, page numbers, and no
stray colour or branding. The **Court Filing** profile (and the whole
Legal / manuscript section) exists so a plain Markdown draft can come out the
other side looking like a compliant filing, without hand-formatting every time.

> **Legal disclaimer:** Markdown Studio is a formatting tool, not legal
> advice, and its output — including the Court Filing profile — is not
> guaranteed to meet any court's requirements. Filing rules vary by
> jurisdiction; always check your local court's rules or consult a licensed
> attorney.

The same machinery serves everyday documents too — **contracts, technical
specs**, branded reports, personal notes — each with its own reusable template.
Write once in Markdown, pick the profile, print. And because profiles are just
JSON, you can [have your AI generate the template itself](ai-profile-authoring.md).

---

## Creating & managing profiles in the app

Open **Print / Export PDF** (the printer icon in the toolbar). The preview
opens in its **own tab** in the tab strip — switch back to the document any
time, and print again to refresh the preview with your latest edits. From
there you can:

| Action | What it does |
| --- | --- |
| **＋ New** | Create a profile from scratch in the visual editor. |
| **✎ Edit** | Modify the selected profile. |
| **⭱ Import** | Load a profile from a `.json` file (see below). |
| **⭳ Export** | Save the selected profile as `<name>.print-profile.json`. |
| **Set as default** | Use this profile for new / unassigned documents. |
| **Pin** | Shows that the selected profile is bound to this file; tap to clear the binding (the document falls back to the default). |

**Selecting a profile for a saved document binds it automatically** — the next
time you print that file, the same profile is preselected. Unsaved documents
have no durable identity yet, so their selection sticks once you save the file
and print again.

The visual editor groups the options into **Identity**, **Branding**, **Branded
styling**, **Header & footer**, **Confidentiality**, **Legal / manuscript**, and
**Layout**. Every field in the [reference](#field-reference) below has a control
there.

## Import / export (the hand-off format)

Profiles round-trip as a single JSON object:

- **Export** writes `<name>.print-profile.json` (pretty-printed).
- **Import** accepts any `.json` file whose top level is an object with at least
  a string **`id`** and a string **`name`**. Everything else is optional and
  falls back to sensible defaults, and out-of-range values are **clamped** on
  import (so a bad number can never produce a broken profile).

This is exactly the shape an AI should emit. To import an AI-generated profile:

1. Save the AI's JSON as `my-template.print-profile.json` (any `.json` name works).
2. In **Print / Export PDF**, click **Import** and pick the file.
3. If a profile with the same `id` exists, you'll be asked to **Replace** it.

> **Logos don't travel.** `logoPath` is an absolute path on *your* machine. When
> you import a profile from elsewhere, a path that doesn't exist here is dropped
> automatically — re-pick the logo in the editor after importing.

---

## Field reference

Every key below is optional **except `id` and `name`**. Types are JSON types.
"Clamp" means an out-of-range imported value is pulled into the allowed range.

### Identity & association

| JSON key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | **required** | Stable identifier. Also the per-document association key. Use a slug like `"acme-report"`. Importing a profile whose `id` matches an existing one offers to replace it. |
| `name` | string | **required** | Display name in the profile picker, e.g. `"Acme — Report"`. |

### Branding

| JSON key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `companyName` | string \| null | `null` | Company / entity name shown in the header (and footer band). |
| `logoPath` | string \| null | `null` | Absolute path to a PNG/JPG logo on the local machine. Not portable across machines (see note above). |
| `logoAlign` | `"left"` \| `"center"` \| `"right"` | `"left"` | Stored for the logo slot. *Note: the running header currently renders the logo left-aligned regardless; this field is persisted for forward compatibility.* |
| `fontFamily` | string | `"Roboto"` | Body font. Must be one of the [supported fonts](#supported-fonts); anything else falls back to Roboto. |
| `primaryColor` | int (ARGB) | `4279903102` (`0xFF1A237E`) | Colour for headings, the header band and accent rules. See [Colours](#colours). |
| `textColor` | int (ARGB) | `4279900698` (`0xFF1A1A1A`) | Body text colour. |
| `accentColor` | int (ARGB) \| null | `null` | Colour for links / secondary accents. `null` = reuse `primaryColor`. |

### Header & footer

| JSON key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `headerText` | string \| null | `null` | Centred header text. If `null` and `showTitleInHeader` is true, the document title is used. |
| `footerText` | string \| null | `null` | Footer text, e.g. `"© 2026 Acme, Inc."`. |
| `showTitleInHeader` | bool | `true` | Show the document title in the header (when `headerText` is not set). |
| `showPageNumbers` | bool | `true` | Show `Page N of M`. |
| `showDate` | bool | `true` | Show the current date. |
| `accentRule` | bool | `true` | Thin accent rule under the header / above the footer. |
| `footerCentered` | bool | `false` | Single centred footer line `Footer — Title \| Page N of M` with a hairline above, instead of the split left/right footer. |
| `coverLogo` | bool | `false` | Place the logo **once** at the top of page 1 (a cover) instead of repeating it in the running header. In this mode the running header also omits the company name. |
| `headingRule` | bool | `false` | Draw a primary-colour underline beneath section headings (h2/h3) for a branded look. |

### Confidentiality

| JSON key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `confidentialLabel` | string \| null | `null` | Classification label shown as a badge in the header band, e.g. `"CONFIDENTIAL"`, `"INTERNAL USE ONLY"`. |
| `watermarkText` | string \| null | `null` | Diagonal background watermark, e.g. `"CONFIDENTIAL"` or `"DRAFT"`. |

### Layout

| JSON key | Type | Default | Clamp | Meaning |
| --- | --- | --- | --- | --- |
| `marginCm` | double | `2.0` | `1.0`–`3.5` | Page margin in centimetres (all four sides). `2.54` = 1 inch. |

### Legal / manuscript

| JSON key | Type | Default | Clamp | Meaning |
| --- | --- | --- | --- | --- |
| `legalMode` | bool | `false` | — | Court-filing output. Monochrome: headings, bold emphasis, links **and** the header/footer chrome (company name, badge, accent rules, footer) all print in the **body text colour** instead of the brand colour. Also sets body text at a uniform **12pt** — captions, list markers and plain `<div>`s included; Markdown headings keep their own sizes (`#####`/h5 renders a 12pt bold title) — keeps one continuous spaced rhythm across paragraph breaks, and lets body paragraphs / list items **flow across page boundaries** so pages fill top to bottom. |
| `justifyBody` | bool | `false` | — | Justify body paragraphs (flush left *and* right) instead of ragged-right. |
| `lineSpacingMultiple` | double | `1.0` | `1.0`–`2.0` | Line-height multiple for body text. `1.0` = single (the classic look), `1.5` = one-and-a-half, `2.0` = double. |
| `firstLineIndentIn` | double | `0.0` | `0.0`–`1.0` | First-line indent for body paragraphs, in **inches** (e.g. `0.5`). `0` = none. |
| `centerHeadings` | bool | `false` | — | Centre headings horizontally (pleading captions / titles). |

---

## Colours

Colours are **32-bit ARGB integers** written in **decimal** (JSON has no hex
literals). The format is `0xAARRGGBB`:

- `AA` = alpha (opacity). **Always use `FF`** (fully opaque). `00` is invisible.
- `RR`, `GG`, `BB` = red, green, blue.

To convert a web hex colour `#RRGGBB` to the decimal value you put in JSON:

```
decimal = 4278190080 + (R × 65536) + (G × 256) + B
```

where `4278190080` is `0xFF000000` (opaque black) and R/G/B are the 0–255
channel values. Common values:

| Name | Hex (`0xAARRGGBB`) | Decimal (use this in JSON) |
| --- | --- | --- |
| Black | `0xFF000000` | `4278190080` |
| Near-black (default text) | `0xFF1A1A1A` | `4279900698` |
| White | `0xFFFFFFFF` | `4294967295` |
| Slate | `0xFF37474F` | `4281812815` |
| Navy | `0xFF0D3B66` | `4279057254` |
| Indigo (default primary) | `0xFF1A237E` | `4279903102` |
| Brand blue | `0xFF4C6FFF` | `4283199487` |
| Teal | `0xFF00695C` | `4278217052` |
| Green | `0xFF2E7D32` | `4281236786` |
| Purple | `0xFF6A1B9A` | `4285143962` |
| Red | `0xFFB71C1C` | `4290190364` |
| Orange | `0xFFEF6C00` | `4293880832` |
| Mid grey | `0xFF666666` | `4284900966` |

## Supported fonts

`fontFamily` must be one of these (fetched from Google Fonts at print time, with
a built-in PDF standard-font fallback when offline). Anything else falls back to
**Roboto**.

`Roboto` · `Inter` · `Lato` · `Open Sans` · `Montserrat` · `Merriweather` ·
`Noto Serif`

For legal / print documents a serif (`Merriweather` or `Noto Serif`) reads best;
`Noto Serif` maps to a Times-like fallback offline.

---

## Worked examples

Each block is a complete, importable profile. Save as
`<something>.print-profile.json` and import it.

### Plain personal

```json
{
  "id": "personal",
  "name": "Personal",
  "fontFamily": "Roboto",
  "primaryColor": 4281812815,
  "textColor": 4279900698,
  "showPageNumbers": true,
  "showDate": true,
  "accentRule": false
}
```

### Branded company report (logo cover + confidentiality)

```json
{
  "id": "acme-report",
  "name": "Acme — Report",
  "companyName": "Acme, Inc.",
  "fontFamily": "Lato",
  "primaryColor": 4279057254,
  "textColor": 4279900698,
  "accentColor": 4283199487,
  "footerText": "© 2026 Acme, Inc.",
  "confidentialLabel": "CONFIDENTIAL",
  "watermarkText": "CONFIDENTIAL",
  "showPageNumbers": true,
  "showDate": true,
  "accentRule": true,
  "headingRule": true,
  "coverLogo": true,
  "marginCm": 2.0
}
```

### Court filing (double-spaced, justified, indented, monochrome)

```json
{
  "id": "court-filing",
  "name": "Court Filing",
  "fontFamily": "Noto Serif",
  "primaryColor": 4278190080,
  "textColor": 4278190080,
  "showPageNumbers": true,
  "showDate": false,
  "showTitleInHeader": false,
  "accentRule": false,
  "marginCm": 2.54,
  "legalMode": true,
  "justifyBody": true,
  "lineSpacingMultiple": 2.0,
  "firstLineIndentIn": 0.5,
  "centerHeadings": true
}
```

---

## Troubleshooting & gotchas

- **Colours look wrong / invisible.** They must be **decimal** ARGB integers with
  an opaque `FF` alpha (add `4278190080`). A value under ~16 million is missing
  its alpha and will render transparent.
- **Font ignored.** `fontFamily` must match the [supported list](#supported-fonts)
  exactly (case-sensitive); otherwise it silently falls back to Roboto.
- **Logo missing after import.** `logoPath` is machine-local and is dropped on
  import when the file isn't found — re-pick it in the editor.
- **Import rejected.** The file must be a JSON **object** (not an array) with
  string `id` and `name`. Remember JSON has **no comments** and no trailing
  commas.
- **My number didn't stick.** `marginCm` (1.0–3.5), `lineSpacingMultiple`
  (1.0–2.0) and `firstLineIndentIn` (0.0–1.0) are clamped to their ranges on
  import.
- **First-line indent + justify.** The indent is exact, but on a first line that
  wraps after only a word or two the justification can leave a slightly larger
  gap right after the indent. This is a rare, cosmetic limitation of the PDF
  engine's justification and is safe to ignore.

## See also

- **[AI profile authoring](ai-profile-authoring.md)** — a self-contained prompt
  you can paste into any AI assistant, plus the machine-readable schema, so it
  generates an importable profile from a plain-English description.
- **[Fill-in lines & inline HTML in PDFs](pdf-inline-html.md)** — signature
  lines, fill-in blanks, redactions, and flex-row captions for printed forms
  and court filings.
