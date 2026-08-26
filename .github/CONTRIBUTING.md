# Contributing to Markdown Studio

Thanks for taking an interest. This is a small project with one maintainer, so
the fastest way to get a change in is to make it easy to review.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Before you write code

- **Open an issue first for anything non-trivial.** A bug fix or a typo can go
  straight to a pull request; a new feature, a dependency change, or a
  refactor is worth agreeing on before you spend the time.
- **Check [`docs/ROADMAP.md`](../docs/ROADMAP.md)** — the feature may already be
  planned, or deliberately out of scope.
- **Licensing.** The project is under the
  [PolyForm Noncommercial License 1.0.0](../LICENSE.md). By opening a pull
  request you agree your contribution is licensed on the same terms.

## Setting up

Full detail lives in [`docs/DEVELOPMENT.md`](../docs/DEVELOPMENT.md). The short
version:

```bash
fvm flutter pub get
fvm flutter run -d windows     # or linux / macos / a connected device
```

**Flutter is pinned to 3.41.9** (see `.fvmrc`) — use FVM, or put a matching
SDK's `bin/` on your `PATH`. Flutter 3.44+ does **not** compile: it added
`TextInputClient.onFocusReceived`, which `appflowy_editor` 6.2.0 doesn't
implement. Note that `flutter analyze` passes on 3.44 even though the build
fails, so a clean analyze is not proof you're on the right SDK.

The native platform folders (`android/`, `ios/`, `linux/`, `macos/`,
`windows/`) can be regenerated with:

```bash
fvm flutter create --org com.markdownstudio --project-name markdown_studio \
  --platforms=android,ios,linux,windows,macos .
```

A few dependencies are pinned or overridden on purpose — `file_picker` at 10.x
(see [issue #2](https://github.com/TheSaltyKorean/md/issues/2)), plus `intl`
and `path_provider_foundation` overrides. Don't bump them casually; the reasons
are in `pubspec.yaml` and `CLAUDE.md`.

## Before you open a pull request

Every change must satisfy all of these:

- [ ] `fvm flutter analyze` is clean.
- [ ] `fvm flutter test` is green.
- [ ] **The version is bumped in `pubspec.yaml`** (`x.y.z+buildNumber`, *both*
      parts) if app behaviour changed at all — a bug fix, a rendering change, a
      new feature. This rides in the same PR. An unbumped build is
      indistinguishable from the last release, so the in-app updater reports
      "no update found" and users never get the fix. Docs-only, CI-only and
      website-only changes don't need one.
- [ ] **Cross-platform is preserved.** Linux, Windows, Android and iOS must all
      still build. No platform-locked code without a guard.
- [ ] **Material 3 with light *and* dark themes** still works in any UI you
      touched.
- [ ] **Printing still works**, including the themeable header/footer and the
      per-document branding profiles. The print preview opens in a workspace
      tab — never a modal dialog.
- [ ] New behaviour has a test. `test/widget_test.dart` is the main suite; the
      PDF builder in particular is covered by rendering a document and
      asserting on the resulting widget tree.

## Pull requests

Open a PR against `main` — `main` is protected, so direct pushes are rejected
and the **`Analyze & test`** check must pass before a merge. CI also builds
Linux, Windows, Android, iOS and macOS on every PR; those take a few minutes
longer than the analyze job.

Keep the README short (badges, download links, highlights) — details belong in
`docs/DEVELOPMENT.md`, `docs/RELEASING.md`, or one of the guides under `docs/`.

Fill in the pull request template so the reviewer can see what changed, how you
tested it, and whether a version bump was needed.

## Reporting bugs and asking for features

Use the [issue templates](https://github.com/TheSaltyKorean/md/issues/new/choose).
For a printing or PDF bug, attaching the source `.md` and, if you can, the
printed PDF makes it enormously faster to reproduce — redact anything private
first. **Never attach a real court filing with personal details in it.**

Security vulnerabilities go through [`SECURITY.md`](SECURITY.md), *not* the
public issue tracker.
