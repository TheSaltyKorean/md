# Turn ChatGPT or Claude output into a formatted PDF

AI assistants answer in **Markdown**: the `#` headings, `**bold**` text,
bullet lists, and tables you see in ChatGPT, Claude, Gemini, and Copilot.
Copying that into a word processor loses half the formatting, and "print
to PDF" from the browser gives you the chat window along with it.

A better route is to keep the answer as Markdown and print it through an app
that understands Markdown. That's what
[Markdown Studio](https://markdownstudio.dev/) is built for: a free Markdown
editor whose PDF export uses reusable **print profiles** for fonts, headers,
footers, page numbers, logos, and watermarks.

## Step by step

1. **Copy the answer as Markdown.** Most assistants have a *Copy* button under
   each reply that copies the raw Markdown. You can also ask:
   *"Give me that as a Markdown document in a code block."*
2. **Paste it into Markdown Studio.** Start a new document and paste. Use
   **Edit** mode to tidy it up like a word processor, or **Split** mode to see
   the Markdown source next to a live preview.
3. **Save it as a `.md` file.** The Markdown is your source of truth. Paste it
   back into the assistant later to revise it, and re-print.
4. **Click the printer icon** and pick a profile, e.g. *Work* for a branded
   report or *Court Filing* for a double-spaced legal document.
5. **Save as PDF.** The text stays selectable and searchable.

## Why keep the source in Markdown?

- **AI assistants edit Markdown well, and PDFs badly.** When you need changes,
  hand the `.md` back and ask. You don't have to re-type anything from a PDF.
- **Formatting is applied at print time.** The same draft can come out as a
  plain memo, a branded company report with a logo and `CONFIDENTIAL`
  watermark, or a court filing, just by switching the profile.
- **It's plain text.** It diffs cleanly in Git, and it opens anywhere.

## Get the assistant to write print-ready Markdown

A few instructions at the start of the chat make the result print better:

> Write this as a Markdown document. Use a single `#` title, `##` section
> headings, numbered lists for steps, and pipe tables for tabular data. Don't
> wrap the whole document in a code block.

For forms and legal documents, the assistant can also use Markdown Studio's
[inline-HTML subset](pdf-inline-html.md) to add signature lines, fill-in
blanks, and forced page breaks. Paste that page into the chat so it knows the
syntax.

## Have the AI design the template too

Print profiles are plain JSON. Paste the
[AI profile authoring prompt](ai-profile-authoring.md) into your assistant,
describe the look ("navy headings, Lato, logo on the cover, page numbers
bottom-centre, DRAFT watermark"), save the JSON it returns, and **Import** it
in the print preview.

## Get Markdown Studio

Free for personal and other non-commercial use on **Windows, Linux, macOS,
Android, and iOS**. On Windows you can also run
`winget install TheSaltyKorean.MarkdownStudio`.

[Download Markdown Studio](https://markdownstudio.dev/#get)

## See also

- [Convert Markdown to PDF with headers, footers, and page numbers](markdown-to-pdf.md)
- [Format a court filing from Markdown](court-filing-from-markdown.md)
- [AI profile authoring](ai-profile-authoring.md)
