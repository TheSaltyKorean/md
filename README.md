# Markdown Studio

[![Support this project on Venmo](https://img.shields.io/badge/%E2%9D%A4%20Support%20this%20project-Venmo-3D95CE?logo=venmo&logoColor=white)](https://venmo.com/u/thesaltykorean)
[![Latest release](https://img.shields.io/github/v/release/TheSaltyKorean/md?label=Latest%20release)](https://github.com/TheSaltyKorean/md/releases/latest)

Write in Markdown, publish polished PDFs — including court-ready filings.
A cross-platform viewer + Notion-style WYSIWYG editor for **Windows, Linux,
Android, iOS and macOS**, built with Flutter.

## Download

| Platform | Get it |
| --- | --- |
| **Windows** | [MSI installer](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-windows-x64.msi) · [setup.exe](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-windows-x64-setup.exe) · [portable zip](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-windows-x64-portable.zip) |
| **Linux** | [.deb package](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-linux-amd64.deb) · [portable tar.gz](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-linux-x64-portable.tar.gz) |
| **Android** | [APK](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-android.apk) (signed) |
| **macOS** | [app zip](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-macos.zip) (unsigned — right-click → Open) |
| **iOS** | [unsigned IPA](https://github.com/TheSaltyKorean/md/releases/latest/download/markdown-studio-ios-unsigned.ipa) (sideload via AltStore/Sideloadly) |

Installers set everything up (Start Menu / desktop entry / file association);
portable builds just extract and run. Step-by-step install notes ship with
[every release](https://github.com/TheSaltyKorean/md/releases/latest).

## Highlights

- **Four view modes** — Notion-style WYSIWYG **Edit**, **Split**
  source + live preview, **Raw** source, read-only **Preview**.
- **Editor comforts** — multi-document tabs (drag to reorder or tear off),
  find & replace (Ctrl/Cmd+F/H), floating format toolbar, drag & drop,
  auto-reload of external changes, light/dark/system themes.
- **Print & PDF studio** — per-document **branding profiles** (fonts,
  colours, logo, headers/footers, watermarks) in a print-preview tab;
  profiles are plain JSON an AI assistant can generate.
- **Court-filing mode** — uniform 12pt, double-spaced, justified,
  first-line indents, monochrome; text flows continuously across pages.
- **Forms & filings in Markdown** — fill-in blanks, signature lines,
  two-column captions, and forced page breaks via a small inline-HTML
  subset.

## Documentation

- [Print & branding profiles](docs/print-profiles.md) — templates, fields,
  worked examples.
- [AI profile authoring](docs/ai-profile-authoring.md) — have an assistant
  generate a template.
- [Fill-in lines & inline HTML in PDFs](docs/pdf-inline-html.md) — blanks,
  signatures, page breaks.
- [Development guide](docs/DEVELOPMENT.md) — toolchain, project layout,
  building from source.
- [Releasing](docs/RELEASING.md) — cutting releases, signing, store
  submission.
- [CLAUDE.md](CLAUDE.md) — contributor working rules.

## Building from source

```bash
# Flutter is pinned to 3.41.9 (see .fvmrc) — 3.44+ does not compile yet.
fvm install && fvm flutter pub get
fvm flutter run -d linux        # or windows / macos / a device
```

Details, platform prerequisites and the full project layout:
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free for personal,
research and other non-commercial use; commercial use requires separate
terms.
