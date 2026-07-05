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

## Store submission

### Google Play (Android)
Upload the release `.aab` in the Play Console; complete the listing,
data-safety form and content rating; roll out to a track. See Flutter's
[Android deployment guide](https://docs.flutter.dev/deployment/android).

### Apple App Store (iOS)
Requires a Mac + Apple Developer account. Set the bundle id and signing team
in Xcode (`ios/Runner.xcworkspace`), then `flutter build ipa --release` and
upload with Transporter or the Xcode Organizer. See
[iOS deployment](https://docs.flutter.dev/deployment/ios).

### Microsoft Store (Windows)
Package as MSIX: add the [`msix`](https://pub.dev/packages/msix) dev
dependency, configure it in `pubspec.yaml`, then `dart run msix:create`
(or `:publish`). The direct-download MSI/setup.exe above are unsigned and
separate from the store path.

### Linux stores
- **Snap:** add `snap/snapcraft.yaml`, run `snapcraft`, publish to the
  Snap Store.
- **Flatpak:** create a manifest packaging the `bundle/` output for Flathub.
- See [Linux deployment](https://docs.flutter.dev/deployment/linux).
