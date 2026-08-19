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

### Cloudflare's AI settings — configured 2026-08-10, re-check if it regresses

Cloudflare ships two AI-crawler controls, both enabled by default. They are
zone settings, so they live in the dashboard, not in this repo — nothing here
can override them.

**Only one of them was actually affecting this site.** Keep the distinction
straight, or a future regression gets diagnosed as two problems when it is one:

| Setting | Dashboard path | Was | Effect here | Now |
| --- | --- | --- | --- | --- |
| Managed robots.txt | **AI Crawl Control → Signals →** "Managed robots.txt" toggle | On | **This was the problem.** Cloudflare overwrote the origin `robots.txt`. | **Off** |
| Block AI training bots | **Overview →** right rail → "Manage AI bot access" → "Block AI training bots" | "Block only on pages with ads" | **Inert** — the site carries analytics but no advertising, so the rule matched nothing. | **"Do not block (allow crawlers)"** |

While Managed robots.txt was on, Cloudflare replaced the origin file with its
own block ("BEGIN Cloudflare Managed content"), declaring
`Content-Signal: search=yes,ai-train=no,use=reference` and `Disallow: /` for
`ClaudeBot`, `GPTBot`, `CCBot`, `Google-Extended`, `Applebot-Extended`,
`Bytespider`, `meta-externalagent` and `Amazonbot` — i.e. every major AI
crawler, on a site whose pitch is "draft with AI". With it off,
`docs/robots.txt` is served verbatim.

The second setting was changed only to remove a latent trap (it would start
biting if ads were ever added), **not** because it was blocking anything. That
is confirmed by measurement: no crawler was ever blocked at the edge —
`ClaudeBot`, `Claude-User`, `GPTBot`, `OAI-SearchBot`, `PerplexityBot` and
`Googlebot` user agents all got `200` throughout. The whole problem was a
policy signal that well-behaved crawlers voluntarily obey.

Verify the origin file is the one being served:

```bash
robots=$(curl -fsS https://markdownstudio.dev/robots.txt) && {
  # Strip comments first. robots.txt explains the Cloudflare marker by name,
  # so grepping the raw body matches this project's own prose and reports a
  # permanent false alarm.
  rules=$(grep -v '^[[:space:]]*#' <<< "$robots")

  printf 'Disallow directives: %s (want 0)\n'    "$(grep -c '^Disallow'  <<< "$rules")"
  printf 'Allow directives:    %s (want >0)\n'   "$(grep -c '^Allow: /'  <<< "$rules")"
  printf 'our file, not CF:    %s (want yes)\n' \
    "$(grep -q '^Sitemap: https://markdownstudio.dev/sitemap.xml' <<< "$rules" \
       && echo yes || echo NO)"
} || echo 'FETCH FAILED — unverified; do NOT read this as a pass'
```

Three properties, because each covers a different failure:

- **`-f`** — without it a 404 or 5xx pipes an error page into `grep`, which
  counts zero `Disallow` lines and makes an outage look like a pass.
- **`Allow` > 0** — an empty body also scores a clean zero on a purely
  negative test.
- **The `Sitemap:` line** — this is the real regression detector. If Cloudflare
  re-enables Managed robots.txt it *replaces* the file wholesale, so this
  project's own directives disappear. Asserting something that must be present
  is more durable than grepping for Cloudflare's marker text, which is a
  comment and could change.

### Agent Readiness

Cloudflare's **Agent Readiness → Diagnostics** page scores the site for AI
agents. As of 2026-08-10 it reports **Level 1 "Quick Wins" 4/5**, with both
items it marks *High impact* (robots.txt, sitemap) green, along with AI Crawler
Rules and Content Signals.

The remaining Level 1 item is **Markdown Negotiation** ("Markdown for Agents" —
serve `text/markdown` to agents that ask for it via `Accept`), which **requires
a Pro plan**. Skipped deliberately, because most of the benefit is already
there for free: every doc is published at **both** a generated `.html` route
and its original `.md` route, and the `.md` route returns the raw source as
`text/markdown` — Jekyll renders the HTML page without removing the source
file. `docs/llms.txt` then gives assistants a plain-text entry point into all
of it.

Confirmed by measurement (2026-08-10) — every one of these returns
`200 text/markdown`, not a rendered page:

```bash
for p in print-profiles pdf-inline-html ai-profile-authoring ROADMAP DEVELOPMENT \
         samples/motion-for-continuance; do
  curl -fsS -o /dev/null -w "%{http_code} %{content_type}  $p.md\n" \
    "https://markdownstudio.dev/$p.md"
done
```

For that to be true of `llms.txt` it has to actually *link* the `.md` routes —
it originally pointed at the `.html` ones, which handed assistants HTML and
made this claim false. Its documentation links are now `.md`, with a note in
the file telling future editors not to "fix" them back.

So the gap Markdown Negotiation closes is genuinely narrow here: an agent that
sends `Accept: text/markdown` to an *`.html`* URL it found via the sitemap or
a search result still gets HTML. One that starts from `llms.txt`, or swaps the
extension, gets Markdown.

Levels 2 and 3 (agent sign-up on behalf of users, API discovery, agent log-in
and tool use) score 0 and are **not applicable** — Markdown Studio is a
downloadable desktop/mobile app, not a hosted service with an API or accounts.
Don't treat those as gaps.

### Analytics & search-engine tagging

Three measurement systems run on the site, plus two search consoles. They are
**not** interchangeable — each sees something the others cannot.

| System | ID / key | Loaded by | Sees |
| --- | --- | --- | --- |
| Google Analytics 4 | `G-GME1XMYJBH` | inline tag in `index.html` + `_includes/head-custom.html` | Page views, events, `download_click`. Cookie-based (region-gated, below). |
| Cloudflare Web Analytics | — | **edge-injected, no code in this repo** | Cookieless page views and Core Web Vitals for every visitor. |
| Google Search Console | `google-site-verification` meta | both head blocks | Google impressions, clicks, queries, index coverage. |
| Bing Webmaster Tools | `msvalidate.01` meta | both head blocks | Bing/Copilot impressions, clicks, AI-citation data. |
| IndexNow | `0f87e00326bb915ddcf83a1d69619b04` | `tool/indexnow.sh` | Push notification of changed URLs to Bing. Write-only; no reporting. |

#### Cloudflare Web Analytics is already on — do not add a snippet

It was enabled a month before this section was written, using **Automatic
setup**: Cloudflare injects `beacon.min.js` at the edge for browser requests.
Nothing in this repo loads it, and nothing should — pasting the JS snippet in
as well would double-count every page view.

This is invisible to `curl`, which is misleading. The origin HTML contains no
beacon, so a `curl | grep cloudflareinsights` returns nothing and looks broken.
Confirm it in a real browser instead: load the site with devtools open and look
for `static.cloudflareinsights.com/beacon.min.js` followed by a `POST` to
`/cdn-cgi/rum` returning `204`.

#### Google Consent Mode v2

`gtag('consent', 'default', …)` runs **before** `gtag.js` loads and is the first
thing pushed to the dataLayer. Order matters: defaults set after the first hit
do not apply to it.

There is no cookie banner, so the EEA/UK/CH default cannot be `granted`. Those
regions get `analytics_storage: 'denied'`, under which GA4 still receives
cookieless pings and models the gap — the defensible posture absent explicit
consent. Everywhere else `analytics_storage` is `granted`. All three advertising
signals are `denied` everywhere, because the site runs no ads and builds no
audiences.

If a consent banner is ever added, it must call `gtag('consent', 'update', …)`
on the user's choice; the defaults here are only the starting state.

#### IndexNow

`bash tool/indexnow.sh` submits the sitemap's URLs to IndexNow, which feeds
**Bing** (plus Yandex, Naver, Seznam). **Google does not consume IndexNow** — it
still finds changes by crawling the sitemap, so this is purely the Bing-side
fast path.

Ownership is proven by `docs/0f87e00326bb915ddcf83a1d69619b04.txt`, whose only content is the key.
**Do not delete that file**; IndexNow refetches it on every submission and
rejects the batch with `403` if it is missing. The script checks the key file is
reachable before submitting, so a deleted key fails loudly instead of silently
no-oping.

```bash
bash tool/indexnow.sh                        # everything in the sitemap
bash tool/indexnow.sh / /print-profiles.html # just these
```

Worth running after any release that changes site content.

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
