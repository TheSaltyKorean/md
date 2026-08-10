# Releasing

How Markdown Studio binaries are built, published, and submitted to stores.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (`x.y.z+buildNumber` — the build number
   must increase for every store upload) and merge to `main`.
2. Tag and push:

   ```bash
   git tag v1.0.2 && git push origin v1.0.2
   ```

3. `.github/workflows/release.yml` builds every platform on GitHub runners
   and publishes a GitHub Release with install notes attached.
4. Update the site's structured data: bump `softwareVersion` and
   `datePublished` in the `SoftwareApplication` JSON-LD block in
   `docs/index.html`, and bump `<lastmod>` for `/` in `docs/sitemap.xml`.
   (Nothing enforces this — it drifted from 1.0.2 to 1.0.19 once.)

Release assets use **stable, versionless names** so the README can deep-link
`releases/latest/download/<name>`:

| Asset | Notes |
| --- | --- |
| `markdown-studio-windows-x64.msi` | WiX MSI (`tool/windows_installer.wxs`): **per-user** (`%LocalAppData%\Programs`, no admin), Start Menu, ARP entry, permanent UpgradeCode → in-place upgrades. The in-app updater installs it silently (`/passive`). Per-user since 1.0.9 — a pre-1.0.9 per-machine (Program Files) copy is a different install context and must be uninstalled once by hand. |
| `markdown-studio-windows-x64-setup.exe` | Inno Setup (`tool/windows_installer.iss`). |
| `markdown-studio-windows-x64-portable.zip` | Bare Release folder. |

All three Windows artifacts bundle the VC++ runtime DLLs (`msvcp140`,
`vcruntime140`, `vcruntime140_1`) copied from the build runner's
redistributable — without them a clean Windows install fails at launch with
`STATUS_DLL_NOT_FOUND` (caught by winget's clean-VM validation).
| `markdown-studio-linux-amd64.deb` | `/opt/markdown-studio`, desktop entry + icon, PATH symlink, `text/markdown` + `text/x-markdown` MIME. Built on Ubuntu 22.04 → depends `libc6 >= 2.35`, `libstdc++6 >= 12`. |
| `markdown-studio-linux-x64-portable.tar.gz` | Bare bundle (glibc 2.35+ distros). |
| `markdown-studio-android.apk` / `.aab` | Only on **signed** releases (see below). |
| `markdown-studio-macos.zip` | Unsigned .app (right-click → Open on first launch). |
| `markdown-studio-ios-unsigned.ipa` | Unsigned; for AltStore/Sideloadly/Xcode re-signing. |

## Dry runs

Run the whole pipeline without publishing:
**Actions → Release → Run workflow** (any branch), or

```bash
gh workflow run release.yml --ref <branch>
```

All build/packaging jobs run and upload artifacts for inspection; the
publish job only runs for a **pushed tag** (a dispatch aimed at a tag ref
still stays a dry run).

## Android signing

Signing values reach Gradle as **environment variables** read by
`android/app/build.gradle.kts` (never a `key.properties` file in CI —
`Properties.load` mangles backslashes in generated passwords). Local builds
can still use the standard `android/key.properties`.

Repo secrets (all four required):

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `upload` |
| `ANDROID_KEY_PASSWORD` | same as the keystore password (PKCS12 keystores have a single password — keytool ignores a separate `-keypass`) |

Without these secrets the release publishes **no Android artifacts** —
debug-signed APKs get a fresh certificate per CI run, which would break
in-place updates between releases.

**Keystore custody:** the keystore exists only in the owner's password
manager (as base64 text) — GitHub secrets are write-only and are *not* a
backup. When creating the Play listing, enroll in **Play App Signing** so
this becomes a resettable upload key.

## winget

Markdown Studio is published to the Windows Package Manager
(`winget install markdown-studio`, identifier
`TheSaltyKorean.MarkdownStudio`; first submission:
[winget-pkgs#398219](https://github.com/microsoft/winget-pkgs/pull/398219)).

Each tagged release updates it automatically: the `winget` job runs
[winget-releaser](https://github.com/vedantmgoyal9/winget-releaser) after the
GitHub Release is published, regenerating the manifests from the release's
MSI and opening the PR to `microsoft/winget-pkgs`. It requires the
**`WINGET_TOKEN`** repo secret — a classic PAT with `public_repo` scope
(the fork + PR are created under that account). Without the secret the job
is skipped and the manifest can be submitted manually (komac/wingetcreate).
The job also checks that the package already exists in `winget-pkgs` and
skips quietly until the initial submission has merged — winget-releaser
fails hard on unknown identifiers.

Note winget's limits: it verifies installer *integrity* (SHA-256), not
publisher identity — the MSI itself is still unsigned — and each version PR
goes through winget-pkgs moderation before `winget upgrade` sees it.

## Store submission

### Microsoft Store (Windows) — setup

> **⚠️ ON HOLD (2026-07-06): do not perform these steps yet — don't reserve
> the name or publish.** The owner is deciding between publishing personally
> and transferring the app to their business (ISV Success program), pending
> an answer from their Microsoft rep on whether the consumer Store satisfies
> the program's publish milestone. See CLAUDE.md → "Distribution & publishing
> state". If the business route is chosen, an IP assignment/license from the
> owner comes first.

One-time (only the account owner can do these):

1. Register a [Partner Center](https://partner.microsoft.com/dashboard)
   **individual** developer account ($19 one-time).
2. **Reserve the app name** "Markdown Studio" (Apps and games → New product).
3. From *Product management → Product identity*, copy three values into repo
   secrets: **`MSIX_IDENTITY_NAME`** (`Package/Identity/Name`, e.g.
   `12345TheSaltyKorean.MarkdownStudio`), **`MSIX_PUBLISHER`**
   (`Package/Identity/Publisher` — the `CN={GUID}` string), and
   **`MSIX_PUBLISHER_DISPLAY_NAME`** (the publisher display name). All three
   are required; the Store packaging step is skipped until they exist.

The MSIX package version carries the pubspec build number as its fourth
part (`1.0.2+3` → `1.0.2.3`), so bumping only the build number still
produces a "newer" package for Partner Center resubmissions.

With those secrets set, every tagged release also produces
`markdown-studio-windows-store.msix` (built with `dart run msix:create
--store`; the Store signs it on publication — no certificate needed). Then
per release: upload that `.msix` in a Partner Center submission, fill the
listing (screenshots, description), point the privacy-policy field at
[`PRIVACY.md`](../PRIVACY.md) (the app's only network requests happen at
print/preview/export time: Google Fonts, and images the document itself
references by URL), complete the age-rating questionnaire, and
submit for certification.

**Pricing/monetization:** the app ships free with an in-app
“Support the project ❤” link (menu → opens the Venmo page in the browser),
which is Store-policy-safe. A paid listing or Store in-app purchases can be
adopted later without code changes to the free path — as the copyright
holder you can sell the app commercially yourself; the PolyForm Noncommercial
license only restricts *others'* commercial use.

### Google Play (Android)
Upload the release `.aab` in the Play Console; complete the listing,
data-safety form and content rating; roll out to a track. See Flutter's
[Android deployment guide](https://docs.flutter.dev/deployment/android).

### Apple App Store (iOS)
Requires a Mac + Apple Developer account. Set the bundle id and signing team
in Xcode (`ios/Runner.xcworkspace`), then `flutter build ipa --release` and
upload with Transporter or the Xcode Organizer. See
[iOS deployment](https://docs.flutter.dev/deployment/ios).

### Linux stores
- **Snap:** add `snap/snapcraft.yaml`, run `snapcraft`, publish to the
  Snap Store.
- **Flatpak:** create a manifest packaging the `bundle/` output for Flathub.
- See [Linux deployment](https://docs.flutter.dev/deployment/linux).

## Website, SEO & AI discoverability

The marketing site is GitHub Pages served from `/docs` on `main`, at
`markdownstudio.dev`, **behind Cloudflare** (the DNS is proxied — responses
carry `server: cloudflare`).

| File | Purpose |
| --- | --- |
| `docs/index.html` | Standalone landing page. No front matter, so Jekyll copies it through verbatim and its hand-written `<head>` survives. Carries its own gtag snippet, meta tags, and JSON-LD. |
| `docs/_config.yml` | Jekyll config for the themed pages: site title, per-page descriptions, `noindex` for contributor-only docs. Without it, every page was titled "… \| md" and shared one meta description. |
| `docs/_includes/head-custom.html` | Injected into every **themed** page's `<head>` (robots directive, theme colour, favicon, gtag). `index.html` duplicates this by hand. |
| `docs/robots.txt` | Explicitly allows search and AI crawlers. |
| `docs/llms.txt` | Machine-readable site summary for AI assistants. Keep it in sync when pages are added or the feature set changes. |
| `docs/sitemap.xml` | Hand-maintained. Add new public pages and bump `<lastmod>`. |

### Cloudflare blocks AI crawlers by default — check this

Cloudflare injects a **managed `robots.txt` block** ("BEGIN Cloudflare Managed
content") into the response. Its default posture is
`Content-Signal: ai-train=no` plus `Disallow: /` for `ClaudeBot`, `GPTBot`,
`CCBot`, `Google-Extended`, `Applebot-Extended`, `Bytespider`,
`meta-externalagent` and `Amazonbot`.

For an app whose pitch is "draft with AI", that is backwards. Turn the managed
AI-crawler blocking **off** in the Cloudflare dashboard (zone
`markdownstudio.dev` → **AI Crawl Control**, and check **Security → Settings**
for a "Block AI bots" / managed robots.txt toggle) so `docs/robots.txt` is what
actually gets served. Verify with:

```bash
curl -s https://markdownstudio.dev/robots.txt
```

The AI crawlers are only *robots.txt*-disallowed, not blocked at the edge —
those user agents still get `200`, so this is purely a policy signal that
well-behaved crawlers obey.

### Download tracking

There are two independent sources, and they measure different things:

- **GA4 (`G-GME1XMYJBH`)** — `docs/index.html` emits a `download_click` event
  (params: `file_name`, `file_extension`, `platform`, `link_url`, `link_text`)
  for every click on a `releases/latest/download/…` link. It uses a distinct
  event name rather than GA4's built-in `file_download`, because enhanced
  measurement only auto-fires for `.exe`/`.zip`/`.gz` — reusing the name would
  double-count those and under-count `.msi`/`.deb`/`.apk`/`.ipa`. This measures
  **website-driven intent only**.
- **GitHub API** — the authoritative cumulative totals, including downloads
  from the releases page, `winget`, and the in-app updater:

  ```bash
  gh api --paginate repos/TheSaltyKorean/md/releases \
    --jq '.[] | .tag_name as $t | .assets[] | "\($t)\t\(.name)\t\(.download_count)"'
  ```

  GitHub only exposes a *current* count, never a history, so a time series
  needs periodic snapshots.
