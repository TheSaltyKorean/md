# Markdown Studio — Privacy Policy

*Last updated: July 5, 2026*

Markdown Studio is a local document editor. **It does not collect, store, or
transmit any personal data, telemetry, analytics, or document content.**

- **Your documents stay on your device.** Files you open, edit, save, print,
  or export are processed entirely locally and are never uploaded anywhere.
- **Settings stay on your device.** Preferences (theme, print profiles,
  per-document profile associations) are stored in local application storage
  only.
- **Your open tabs stay on your device.** To reopen where you left off after
  a restart or update, the app saves your open documents — including any
  unsaved text — to a `session.json` file in its local application-support
  folder. It is read only to restore your tabs and is never transmitted
  anywhere.
- **Network use — three kinds, none carrying your data.** (1) When printing
  or exporting a PDF with a Google Fonts typeface, the app downloads that
  font file from Google Fonts (fonts.google.com); offline it falls back to
  built-in fonts. (2) When a document itself references an image by URL
  (`![…](https://…)`), the app fetches that image from the URL the document
  names so it can appear in the printed PDF; offline (or if the fetch fails)
  a placeholder is printed instead. (3) At launch the app asks GitHub
  for the latest release version so it can offer a one-click update — turn
  it off any time via menu → *Check on startup*. In every case only a
  standard, anonymous file/version request is made; no document content or
  personal information is ever sent.
- **No accounts, no ads, no third-party SDKs.**

External links opened from the app (e.g. the support page or links in your
documents) are handled by your browser and are subject to those sites' own
policies.

Questions: open an issue at
<https://github.com/TheSaltyKorean/md/issues>.
