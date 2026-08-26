## What this changes

<!-- A sentence or two. Link the issue if there is one: "Fixes #123". -->

## Why

<!-- The problem being solved, or the behaviour that was wrong. -->

## How it was tested

<!-- Commands you ran, platforms you ran them on, documents you printed.
     Screenshots are welcome for anything visual, before/after for a
     rendering change. -->

## Checklist

- [ ] `fvm flutter analyze` is clean
- [ ] `fvm flutter test` is green
- [ ] `version:` bumped in `pubspec.yaml` (both `x.y.z` and `+build`) — or this
      is a docs-only / CI-only / website-only change that doesn't need one
- [ ] Cross-platform preserved (Linux, Windows, Android, iOS still build; no
      unguarded platform-specific code)
- [ ] Material 3 and both light and dark themes still look right
- [ ] Printing still works, including headers/footers and branding profiles —
      and the print preview is still a workspace tab, not a dialog
- [ ] New behaviour is covered by a test
