#!/bin/bash
# Builds a release Earmark.app from the SwiftPM package in app/.
#
#   scripts/build-app.sh            -> app/build/Earmark.app
#
# SwiftPM only produces a bare executable plus resource bundles, so this wraps
# them into an .app: Info.plist (bundle id, usage strings for removable volumes
# and the protected user folders), resource bundles in Contents/Resources
# (where UCSCatalog.bundledResource looks), then ad hoc signing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app"
OUT="$PKG/build"
APP="$OUT/Earmark.app"
BUNDLE_ID="io.github.christian-ofigueiredo.Earmark"
VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo 0)"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$PKG"
swift build -c release --product Earmark
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Earmark" "$APP/Contents/MacOS/Earmark"
for b in "$BIN"/*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Earmark</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Earmark</string>
    <key>CFBundleDisplayName</key><string>Earmark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Earmark reads the sound and music libraries you add from external drives. It never changes your files.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Earmark reads the sound and music libraries you add from network drives. It never changes your files.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Earmark reads the sound and music libraries you add from your Desktop. It never changes your files.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Earmark reads the sound and music libraries you add from Documents. It never changes your files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Earmark reads the sound and music libraries you add from Downloads. It never changes your files.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
