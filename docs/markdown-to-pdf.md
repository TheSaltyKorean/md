# Convert Markdown to PDF with headers, footers, and page numbers

Most Markdown-to-PDF converters give you one look: whatever their default
stylesheet happens to be. Getting a logo in the header, `Page 3 of 12` in the
footer, a `DRAFT` watermark, or a specific font usually means writing CSS,
a LaTeX template, or a Pandoc filter.

[Markdown Studio](https://markdownstudio.dev/) is a free desktop and mobile
Markdown editor that exports PDFs through reusable **print profiles**. A profile
is a saved look (font, colours, logo, header, footer, page size, margins,
watermark) that you pick in a print-preview tab. It needs no command line and
no CSS.

## Quick steps

1. **Open or paste your Markdown.** Open a `.md` file, drag it onto the window,
   or start a new document and paste. This works for README files, notes, and
   text from an AI assistant alike.
2. **Click the printer icon** (Print / Export PDF). A print preview opens in
   its own tab next to your document.
3. **Pick a profile**: *Personal*, *Work*, or *Court Filing* are built in.
   You can also create your own with **＋ New**.
4. **Choose the page size** (A4, US Letter, or Legal) and orientation.
5. **Save as PDF.** The exported PDF keeps **selectable, searchable text**.
   It isn't a screenshot of the page. You can also send it straight to a
   printer or share it.

Edit the document, print again, and the preview refreshes. For a saved file,
Markdown Studio remembers which profile you picked, so the same report always
comes out with the same branding.

## What you can control

| Want this in your PDF | Profile setting |
| --- | --- |
| Company name and logo in the header, or a logo cover on page 1 | `companyName`, `logoPath`, `coverLogo` |
| Custom header / footer text | `headerText`, `footerText` |
| `Page N of M` page numbers | `showPageNumbers` |
| Today's date in the header | `showDate` |
| A `CONFIDENTIAL` / `INTERNAL USE ONLY` badge | `confidentialLabel` |
| A diagonal `DRAFT` or `CONFIDENTIAL` watermark | `watermarkText` |
| Brand colours for headings and accent rules | `primaryColor`, `accentColor`, `headingRule` |
| A different body font (Inter, Lato, Merriweather, Noto Serif…) | `fontFamily` |
| A4, US Letter, or Legal paper; margins | `pageSize`, `marginCm` |
| Double spacing, justified text, first-line indents | `lineSpacingMultiple`, `justifyBody`, `firstLineIndentIn` |

Every field is described in the
[print & branding profiles reference](print-profiles.md). The visual editor has
a control for each one, so you never have to touch JSON unless you want to.

## Things plain Markdown can't do, and how to get them anyway

Markdown has no syntax for a signature line, a fill-in blank, or a forced page
break. Markdown Studio's PDF renderer understands a
[small inline-HTML subset](pdf-inline-html.md) for exactly those:

```markdown
Signed: <span style="display:inline-block; min-width:216pt; border-bottom:1px solid #000;"> </span>

<div style="page-break-before:always"></div>

## Appendix A
```

Tables (pipe tables or HTML `<table>` with cell colours), images, code blocks,
block quotes, and lists all print as well.

## Let an AI design the template

Profiles are plain JSON, so you don't have to build one by hand. Describe the
look you want to ChatGPT, Claude, Gemini, or Copilot, and use the
[AI profile authoring prompt](ai-profile-authoring.md) to get an importable
profile back. Then click **Import** in the print preview.

## Markdown to PDF on every platform

Markdown Studio is one app for **Windows, Linux, macOS, Android, and iOS**, so
the same profile gives the same PDF on each. On Windows you can also install it
from the command line:

```
winget install TheSaltyKorean.MarkdownStudio
```

[Download Markdown Studio](https://markdownstudio.dev/#get). It's free for
personal and other non-commercial use.

## See also

- [Turn ChatGPT or Claude output into a formatted PDF](ai-output-to-pdf.md)
- [Format a court filing from Markdown](court-filing-from-markdown.md)
- [Print & branding profiles reference](print-profiles.md)
