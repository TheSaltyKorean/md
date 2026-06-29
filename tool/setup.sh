#!/usr/bin/env bash
# Markdown Studio — macOS/Linux setup script
# Generates the native platform projects (android/ios/linux/...) that are NOT
# checked into source control, then fetches dependencies.
#
# Prerequisites: Flutter SDK on PATH (https://docs.flutter.dev/get-started/install)
# Usage:  ./tool/setup.sh
set -euo pipefail

echo "==> Checking Flutter..."
flutter --version

# Backfill native platform folders into this existing project without touching
# lib/ or pubspec.yaml. Change --org to your reverse-domain identifier; it
# becomes the base of your app/bundle ID for the stores.
echo "==> Generating native platform projects..."
flutter create --org com.markdownstudio --project-name markdown_studio \
  --platforms=android,ios,linux,macos .

echo "==> Fetching packages..."
flutter pub get

echo "==> Done. Try: flutter run -d linux   (or -d macos / a device)"
