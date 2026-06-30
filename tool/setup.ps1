# Markdown Studio — Windows setup script
# Generates the native platform projects (android/ios/linux/windows) that are
# NOT checked into source control, then fetches dependencies.
#
# Prerequisites: Flutter SDK on PATH (https://docs.flutter.dev/get-started/install)
# Usage:  pwsh ./tool/setup.ps1

$ErrorActionPreference = "Stop"

Write-Host "==> Checking Flutter..." -ForegroundColor Cyan
flutter --version

# Backfill native platform folders into this existing project without touching
# lib/ or pubspec.yaml. Change --org to your reverse-domain identifier; it
# becomes the base of your app/bundle ID for the stores.
Write-Host "==> Generating native platform projects..." -ForegroundColor Cyan
flutter create --org com.markdownstudio --project-name markdown_studio `
  --platforms=android,ios,linux,windows .

Write-Host "==> Fetching packages..." -ForegroundColor Cyan
flutter pub get

Write-Host "==> Done. Try: flutter run -d windows" -ForegroundColor Green
