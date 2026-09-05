#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release --product MusicPlayer

APP_NAME="Music Player.app"
BUILD_DIR=".build/release"
APP_DIR="Build/${APP_NAME}"

rm -rf "Build"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/MusicPlayer" "${APP_DIR}/Contents/MacOS/MusicPlayer"
cp "AppResources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "AppResources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Copy any resource bundles produced by SPM (e.g. for dependencies) alongside the executable.
if ls "${BUILD_DIR}"/*.bundle >/dev/null 2>&1; then
    cp -R "${BUILD_DIR}"/*.bundle "${APP_DIR}/Contents/Resources/"
fi

# A stable local identity, not ad-hoc (`-sign -`) — an ad-hoc signature is
# derived from the binary's own contents, so it changes on every rebuild
# and macOS's privacy system (mic access, etc.) sees each rebuild as a new
# app and re-asks. This certificate is self-signed and lives only in this
# Mac's login keychain (see the "MusicPlayerLocalDev" identity) — signing
# with it keeps the app's identity stable across rebuilds instead.
codesign --force --deep --sign "MusicPlayerLocalDev" "${APP_DIR}" >/dev/null 2>&1

echo "Built: ${APP_DIR}"
