#!/bin/bash
# Builds a release Earmark.app from the SwiftPM package in app/.
#
#   scripts/build-app.sh            -> app/build/Earmark.app, then installed in /Applications
#   scripts/build-app.sh --no-install  -> app/build/Earmark.app only
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
# The release tag (v0.1.0-alpha.1): the full name for display, and its numbers alone for
# CFBundleShortVersionString, which macOS wants as three integers.
VERSION="$(git -C "$ROOT" describe --tags --match 'v*' --abbrev=0 2>/dev/null || echo v0.0.0)"
VERSION="${VERSION#v}"
SHORT_VERSION="${VERSION%%-*}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
MIN_MACOS="14.0"   # as in app/Package.swift

# The Rust engine and its Swift bindings (app/Engine, app/Sources/EarmarkEngine/Generated).
"$ROOT/scripts/build-engine.sh"
cd "$PKG"
swift build -c release --product Earmark
swift build -c release --product earmark-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Earmark" "$APP/Contents/MacOS/Earmark"
# The MCP server agents start (docs/mcp-plan.md), beside the app: the Rust engine's since step 8c
# (docs/rust-engine-plan.md). The Swift one stays beside it as earmark-mcp-swift, for an agent
# pointed there if the Rust one misbehaves.
cp "$ROOT/engine/target/release/earmark-mcp" "$APP/Contents/MacOS/earmark-mcp"
cp "$BIN/earmark-mcp" "$APP/Contents/MacOS/earmark-mcp-swift"
# SwiftPM records the deployment target as the SDK the binary was built with
# (LC_BUILD_VERSION "sdk 14.0"), and macOS draws apps built for an old SDK in the
# old design: old window buttons and controls, no Liquid Glass. Record the SDK
# actually used, keeping the minimum system version.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "$MIN_MACOS" "$SDK_VERSION" -replace \
    -output "$APP/Contents/MacOS/Earmark.sdk" "$APP/Contents/MacOS/Earmark" 2>/dev/null
mv "$APP/Contents/MacOS/Earmark.sdk" "$APP/Contents/MacOS/Earmark"
for b in "$BIN"/*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
done
# The type: Tessel and Brakwell (app/Fonts), registered for the app alone by ATSApplicationFontsPath.
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$PKG"/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
# The icon: an Icon Composer file (app/Icon/AppIcon.icon, Liquid Glass layers), compiled into
# Assets.car with an AppIcon.icns for older systems.
# The accent colour (app/Icon/Accent.xcassets): the design system's muted ink, so the system's
# controls (selection, checkboxes, focus) aren't the system's blue.
xcrun actool "$PKG/Icon/AppIcon.icon" "$PKG/Icon/Accent.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target "$MIN_MACOS" --app-icon AppIcon --accent-color AccentColor \
    --output-partial-info-plist "$(mktemp -t earmark-icon)" > /dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Earmark</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSAccentColorName</key><string>AccentColor</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>earmark</string></array>
        </dict>
    </array>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Earmark</string>
    <key>CFBundleDisplayName</key><string>Earmark</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>EarmarkVersion</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Version $VERSION · MIT License</string>
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

# Install a copy in /Applications. The build in app/build stays: the MCP server agents
# start is registered at that path. A copy running from /Applications is asked to quit,
# then replaced and opened again.
if [ "${1:-}" != "--no-install" ]; then
    DEST="/Applications/Earmark.app"
    RUNNING=0
    if pgrep -f "$DEST/Contents/MacOS/Earmark\$" >/dev/null; then
        RUNNING=1
        osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
        while pgrep -f "$DEST/Contents/MacOS/Earmark\$" >/dev/null; do sleep 0.2; done
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    echo "Installed $DEST"
    if [ "$RUNNING" = 1 ]; then open "$DEST"; fi
fi
