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

Release assets use **stable, versionless names** so the README can deep-link
`releases/latest/download/<name>`:

| Asset | Notes |
| --- | --- |
| `markdown-studio-windows-x64.msi` | WiX MSI (`tool/windows_installer.wxs`): Program Files, Start Menu, ARP entry, permanent UpgradeCode → in-place upgrades. |
| `markdown-studio-windows-x64-setup.exe` | Inno Setup (`tool/windows_installer.iss`). |
| `markdown-studio-windows-x64-portable.zip` | Bare Release folder. |
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
