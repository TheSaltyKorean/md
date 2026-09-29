# Format a court filing from Markdown

Court filings have strict layout rules: US Letter paper, 1-inch margins, a
12-point serif font, double spacing, numbered pages, and a caption at the top.
Getting all of that right in a word processor is fiddly, and it's easy to break
when you edit the document later. It's harder still when an AI assistant drafted
the text and you're pasting it in.

[Markdown Studio](https://markdownstudio.dev/) was built for this. It came out
of a real **pro se** litigant's workflow. You write the motion in plain
Markdown, and the built-in **Court Filing** profile prints it as a pleading-style
PDF.

> **Not legal advice.** Markdown Studio is a formatting tool. Formatting rules
> vary by court and jurisdiction, and its output isn't guaranteed to meet any
> particular court's requirements. Always check your local rules, or ask a
> licensed attorney or the clerk's office.

## What the Court Filing profile does

- **US Letter** paper with **1-inch** margins
- A **12pt serif** body (Noto Serif, which falls back to a Times-like face
  offline)
- **Double spacing** that stays continuous across paragraph breaks
- **Justified** paragraphs with a **0.5-inch first-line indent**
- **Centred headings** for court names and document titles
- **Monochrome** output with no brand colour anywhere, including the header
  and footer
- **Page numbers**, with paragraphs and list items that **flow across pages**
  so every page fills top to bottom

Every one of these is adjustable. Copy the profile and change the margins,
font, or spacing to match your court's rules. The
[profile reference](print-profiles.md#legal--manuscript) lists each setting.

## A motion in Markdown

Here's the start of a real example: the court header, a two-column case
caption, and the title.

```markdown
<div style="text-align:center">IN THE CIRCUIT COURT OF BENTON COUNTY, ARKANSAS<br>DOMESTIC RELATIONS DIVISION</div>

<div style="display:flex; justify-content:space-between"><div>JANE EXAMPLE</div><div>PLAINTIFF</div></div>

<div style="display:flex; justify-content:space-between"><div>v.</div><div>Case No. 04DR-2026-123-4</div></div>

<div style="display:flex; justify-content:space-between"><div>JOHN EXAMPLE</div><div>DEFENDANT</div></div>

#### <u>MOTION FOR CONTINUANCE</u>

Comes now the Defendant, appearing pro se, and for his Motion for Continuance states as follows.

1. The hearing in this matter is currently set for a date on which ...
```

The body is ordinary Markdown: paragraphs and a numbered list. The HTML only
handles what Markdown can't express, such as centring, the side-by-side caption
columns, and underlined titles.

- [Read the full sample motion](samples/motion-for-continuance.html)
  ([raw `.md`](https://markdownstudio.dev/samples/motion-for-continuance.md))
- [See the printed PDF](samples/motion-for-continuance.pdf)

## Certificate of service, signature lines, and blanks

Put the **certificate of service on its own page** with a page-break directive,
and add a signature line with an empty bordered `<div>`:

```markdown
<div style="page-break-before:always"></div>

#### <u>CERTIFICATE OF SERVICE</u>

I hereby certify that a true and correct copy of the foregoing was served on
all counsel of record this ____ day of July, 2026.

<div style="margin-top:36px; width:40%; border-bottom:1px solid #000"></div>

<div>JOHN EXAMPLE, pro se</div>
```

Fill-in blanks, redactions, and aligned blocks are covered in
[fill-in lines & inline HTML](pdf-inline-html.md).

## Drafting with AI

Legal drafting is a natural fit for AI assistants, and they already write
Markdown. Ask the assistant for the motion in Markdown, paste the
[sample motion](https://markdownstudio.dev/samples/motion-for-continuance.md) in as a template so it copies
the caption layout, then paste the result into Markdown Studio and print with
*Court Filing*. When you need a revision, hand the `.md` back to the assistant.
You don't have to re-format anything. See
[turning AI output into a PDF](ai-output-to-pdf.md).

AI assistants can make up case citations. Check every citation and fact
before you file.

## Get Markdown Studio

Free for personal and other non-commercial use on **Windows, Linux, macOS,
Android, and iOS**. On Windows you can also run
`winget install TheSaltyKorean.MarkdownStudio`.

[Download Markdown Studio](https://markdownstudio.dev/#get)

## See also

- [Convert Markdown to PDF with headers, footers, and page numbers](markdown-to-pdf.md)
- [Fill-in lines & inline HTML in PDFs](pdf-inline-html.md)
- [Print & branding profiles reference](print-profiles.md)
