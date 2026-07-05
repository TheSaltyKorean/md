# AI profile authoring — hand a template to your assistant

This page lets you **describe a template in plain English and have any AI
assistant generate an importable profile** for Markdown Studio's Print / Export
PDF feature. Copy the block below into your assistant, add your description, and
import the JSON it returns.

For the human-readable explanation of every field, see
[Print & branding profiles](print-profiles.md).

---

## How to use it

1. Copy the **entire** prompt block in the next section into your AI assistant.
2. After it, describe what you want, e.g.
   *"A profile for federal court motions: Times-like serif, double-spaced,
   justified, 0.5-inch first-line indent, 1-inch margins, page numbers, no date,
   centred headings, black-and-white."*
3. Save the assistant's reply as `my-template.print-profile.json`.
4. In Markdown Studio: **Print / Export PDF → Import**, and pick the file.

---

## Copy-paste prompt block

````text
You are generating a "print profile" for the app **Markdown Studio**. Output
**one JSON object only** — no prose, no Markdown fences, no comments (JSON does
not allow comments or trailing commas). The object must be directly importable.

REQUIRED keys:
- "id": string. A stable kebab-case slug, e.g. "acme-report".
- "name": string. Human label, e.g. "Acme — Report".

OPTIONAL keys (omit any you don't need; these are the defaults):
- "companyName": string|null = null        // header/footer company name
- "logoPath": null                          // ALWAYS null; logos are added in-app
- "logoAlign": "left"|"center"|"right" = "left"
- "fontFamily": string = "Roboto"           // MUST be one of the allowed fonts below
- "primaryColor": integer = 4279903102      // ARGB decimal (see COLOURS)
- "textColor": integer = 4279900698         // ARGB decimal
- "accentColor": integer|null = null        // links; null = use primaryColor
- "headerText": string|null = null          // null => use document title if showTitleInHeader
- "footerText": string|null = null
- "showTitleInHeader": boolean = true
- "showPageNumbers": boolean = true
- "showDate": boolean = true
- "accentRule": boolean = true              // thin rule under header / above footer
- "footerCentered": boolean = false         // single centred footer line w/ page count
- "coverLogo": boolean = false              // logo once at top instead of running header
- "headingRule": boolean = false            // coloured underline beneath h2/h3
- "confidentialLabel": string|null = null   // e.g. "CONFIDENTIAL" badge in header
- "watermarkText": string|null = null       // diagonal background watermark
- "marginCm": number = 2.0                  // page margin, cm; RANGE 1.0–3.5; 2.54 = 1 inch
- "legalMode": boolean = false              // court output: monochrome chrome, uniform 12pt body,
                                            // continuous spacing rhythm, text flows across pages
- "justifyBody": boolean = false            // justify body paragraphs
- "lineSpacingMultiple": number = 1.0       // 1.0 single, 1.5, 2.0 double; RANGE 1.0–2.0
- "firstLineIndentIn": number = 0.0         // first-line indent in INCHES; RANGE 0.0–1.0
- "centerHeadings": boolean = false         // centre headings (captions/titles)

ALLOWED fontFamily values (exact, case-sensitive; anything else falls back to
Roboto): "Roboto", "Inter", "Lato", "Open Sans", "Montserrat", "Merriweather",
"Noto Serif". For legal/formal documents prefer "Noto Serif" or "Merriweather".

COLOURS — every colour is a 32-bit ARGB integer written in DECIMAL (JSON has no
hex). Format 0xAARRGGBB: AA = alpha (ALWAYS FF = opaque), then R,G,B.
Convert a web hex #RRGGBB with: decimal = 4278190080 + R*65536 + G*256 + B.
Ready-made values:
  black          #000000 -> 4278190080
  near-black text#1A1A1A -> 4279900698
  white          #FFFFFF -> 4294967295
  slate          #37474F -> 4281812815
  navy           #0D3B66 -> 4279057254
  indigo         #1A237E -> 4279903102
  brand blue     #4C6FFF -> 4283199487
  teal           #00695C -> 4278217052
  green          #2E7D32 -> 4281236786
  purple         #6A1B9A -> 4285143962
  red            #B71C1C -> 4290190364
  orange         #EF6C00 -> 4293880832
For legal/black-and-white output set primaryColor AND textColor to 4278190080
(black) and legalMode = true.

RULES:
- Output valid JSON: double-quoted keys/strings, no comments, no trailing commas.
- Respect the numeric RANGES above (values outside are clamped on import, so stay
  inside them).
- Keep "logoPath" null — the user attaches the logo in the app afterward.
- Choose an "id" that is a unique kebab-case slug.

Now produce the profile for this request:
<DESCRIBE YOUR TEMPLATE HERE>
````

---

## Minimal valid output

The smallest acceptable object:

```json
{ "id": "blank", "name": "Blank" }
```

Everything else defaults. A realistic answer fills in the keys that matter for
the request and leaves the rest out.

## Worked example

**Request appended to the prompt:**

> A profile for state-court pleadings: serif, double-spaced, justified, 0.5"
> first-line indent, 1" margins, centred headings, page numbers, no date,
> black-and-white.

**Expected output:**

```json
{
  "id": "state-pleading",
  "name": "State Pleading",
  "fontFamily": "Noto Serif",
  "primaryColor": 4278190080,
  "textColor": 4278190080,
  "showDate": false,
  "showTitleInHeader": false,
  "showPageNumbers": true,
  "accentRule": false,
  "marginCm": 2.54,
  "legalMode": true,
  "justifyBody": true,
  "lineSpacingMultiple": 2.0,
  "firstLineIndentIn": 0.5,
  "centerHeadings": true
}
```

## Validation checklist

Before importing, confirm the JSON:

- [ ] is a single **object** (starts `{`, ends `}`), not an array;
- [ ] has string `id` and `name`;
- [ ] uses **decimal** colour integers ≥ `4278190080` (opaque);
- [ ] uses a `fontFamily` from the allowed list;
- [ ] keeps `marginCm` 1.0–3.5, `lineSpacingMultiple` 1.0–2.0,
      `firstLineIndentIn` 0.0–1.0;
- [ ] has `logoPath` set to `null`;
- [ ] contains **no comments or trailing commas**.

If the import is rejected, it's almost always a stray comment, a trailing comma,
or a colour written in hex instead of decimal.
