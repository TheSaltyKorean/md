# Fill-in lines & inline HTML in PDFs

Markdown alone can't express everything a printed **form or court filing**
needs — a signature line, a "Name: ______" blank, a two-column caption, a
centred title block. Markdown Studio's PDF renderer understands a small,
deliberate subset of inline HTML/CSS so those documents come out right when
you **print or export to PDF**, while the source stays plain Markdown that an
AI assistant can read and edit.

> **Scope:** this page describes what the **PDF renderer** supports (the
> Print / Export PDF preview tab). The on-screen Markdown preview may render
> these snippets more plainly — judge the result in the print preview.

## Quick reference

| Construct | Renders as |
| --- | --- |
| `<u>text</u>`, `<ins>text</ins>` | Underlined text |
| `<del>text</del>` | Struck-through text |
| `<br>` | Line break |
| `<span style="border-bottom:…">` (no text) | A fill-in blank line |
| `<span style="color:…; font-weight:…">text</span>` | A styled inline label |
| `<span style="color:transparent">…</span>` | Redacted (invisible) text |
| `<div style="border-bottom:…"></div>` | A block signature line |
| `<div style="text-align:center">…</div>` | Aligned block text |
| `<div style="display:flex">…</div>` | Divs laid out side by side (a row) |

## Fill-in blanks (inline `<span>`)

A span with a **visible `border-bottom`** and no real text renders as a blank
line sitting on the text baseline — the classic fill-in field:

```markdown
Name: <span style="display:inline-block; min-width:150px; border-bottom:1px solid #555;"> </span>
Date: <span style="display:inline-block; min-width:108px; border-bottom:1px solid #555;"> </span>
```

Details the renderer honours:

- **Width** — `width` or `min-width` in `px`, `pt`, or `%` (percentages are
  resolved against the line width). If both are given, the larger wins. With
  no usable width, the blank defaults to **108 pt** (about 1.5 inches).
  `width:0` (or `width:0%`) deliberately collapses the span to nothing.
- **Border** — the `border-bottom` shorthand and the
  `border-bottom-width/-style/-color` longhands are all parsed. A border with
  `style:none/hidden`, zero width, or a transparent colour counts as
  invisible (so the span is not treated as a blank). Very thin borders are
  drawn at a minimum of 0.6 pt so they survive printing.
- **Colour** — a border with no colour of its own uses the surrounding text
  colour.

## Styled labels (inline `<span>` with text)

A span **with text** becomes a styled run inside the paragraph:

```markdown
Status: <span style="color:#c00; font-weight:bold;">OVERDUE</span>
```

Supported properties: `color`, `font-weight` (`bold` or numeric ≥ 600),
`font-style: italic`, `font-size`, and `text-decoration: underline` /
`line-through` (combined with any surrounding decoration).

**Redaction:** `color: transparent` hides the text while keeping its space —
on a span itself or inherited from a wrapping span. Combined with a visible
`border-bottom` it draws the blank without the text.

Spans nest (inner spans inherit the outer style), uppercase `<SPAN>` works,
HTML entities in prose are decoded (`&amp;` → `&`, `&nbsp;` → space), and
stray, unclosed, or self-closing span tags are stripped rather than leaking
into the output.

## Block layout (`<div>`)

A `<div>` on its own line(s) is a block-level element:

- **Signature line** — an empty div with a visible `border-bottom` draws a
  standalone rule:

  ```markdown
  <div style="width:40%; border-bottom:1px solid #000;"></div>
  <div>Respondent's signature</div>
  ```

- **Alignment** — `text-align: left | center | right | justify` on a div with
  text aligns it across the page (e.g. a centred court title block).

- **Rows** — `display:flex` on a wrapper div lays its child divs out side by
  side; `flex-direction: column` stacks them instead, and `justify-content`
  maps to the row's alignment. Child widths can be fixed lengths or
  percentages (percentages become proportional flex). This is how a
  two-column court caption (party names left, case number right) is built:

  ```markdown
  <div style="display:flex;">
    <div style="width:60%;">JANE DOE,<br>Petitioner</div>
    <div style="width:40%; text-align:right;">Case No. 12-3456</div>
  </div>
  ```

  Wrapper divs nest: a div containing more divs recurses into a column or
  row, and children inside a row shrink to fit rather than overflowing.
  Inner `<b>` tags and HTML entities are handled.

## Limitations

- **Spans wrapping Markdown syntax.** When a span wraps Markdown emphasis or
  a link (e.g. `<span style="color:red">**bold**</span>`), the Markdown
  parser splits the tags away from the inner element. The tags never leak
  and the emphasis still renders, but the span's own colour/weight is not
  applied to that inner element. Style the plain text directly instead.
- **Entities in code.** HTML entities are decoded in prose but left verbatim
  inside code spans and code blocks (by design).
- **Everything else is text.** HTML tags outside this subset are not
  interpreted by the PDF renderer.

## See also

- **[Print & branding profiles](print-profiles.md)** — fonts, colours,
  headers/footers, watermarks, and the legal / manuscript layout options
  (double spacing, justification, first-line indent, centred headings).
- **[AI profile authoring](ai-profile-authoring.md)** — have an AI generate
  an importable print profile from a plain-English description.
