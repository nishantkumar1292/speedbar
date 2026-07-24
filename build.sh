#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRODUCT_NAME="SpeedBar"
EXECUTABLE_NAME="InternetSpeed"
BUNDLE_IDENTIFIER="com.nishantkumar.speedbar"
MINIMUM_MACOS_VERSION="12.0"
VERSION="${VERSION:-0.2.0}"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "error: VERSION must contain one to three dot-separated integers (for example, 0.2.0)." >&2
    exit 1
fi

BUILD_ROOT="$SCRIPT_DIR/.build/speedbar-release"
ARM64_SCRATCH="$BUILD_ROOT/arm64"
X86_64_SCRATCH="$BUILD_ROOT/x86_64"
mkdir -p "$BUILD_ROOT"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/speedbar-staging.XXXXXX")"
STAGED_APP="$STAGING_ROOT/$PRODUCT_NAME.app"
OUTPUT_APP="$SCRIPT_DIR/$PRODUCT_NAME.app"

cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

echo "Building $PRODUCT_NAME $VERSION for macOS $MINIMUM_MACOS_VERSION+..."

swift build \
    --package-path "$SCRIPT_DIR" \
    --configuration release \
    --product "$EXECUTABLE_NAME" \
    --triple "arm64-apple-macosx$MINIMUM_MACOS_VERSION" \
    --scratch-path "$ARM64_SCRATCH" \
    --disable-index-store

swift build \
    --package-path "$SCRIPT_DIR" \
    --configuration release \
    --product "$EXECUTABLE_NAME" \
    --triple "x86_64-apple-macosx$MINIMUM_MACOS_VERSION" \
    --scratch-path "$X86_64_SCRATCH" \
    --disable-index-store

ARM64_BINARY="$ARM64_SCRATCH/arm64-apple-macosx/release/$EXECUTABLE_NAME"
X86_64_BINARY="$X86_64_SCRATCH/x86_64-apple-macosx/release/$EXECUTABLE_NAME"
STAGED_EXECUTABLE="$STAGED_APP/Contents/MacOS/$EXECUTABLE_NAME"

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
lipo -create "$ARM64_BINARY" "$X86_64_BINARY" -output "$STAGED_EXECUTABLE"
chmod 755 "$STAGED_EXECUTABLE"
cp "$SCRIPT_DIR/assets/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"

cat > "$STAGED_APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>$PRODUCT_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MINIMUM_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

plutil -lint "$STAGED_APP/Contents/Info.plist"
xattr -cr "$STAGED_APP"
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

PREVIOUS_APP=""
if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
    PREVIOUS_APP="$STAGING_ROOT/previous-$PRODUCT_NAME.app"
    mv "$OUTPUT_APP" "$PREVIOUS_APP"
fi

if ! mv "$STAGED_APP" "$OUTPUT_APP"; then
    if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" ]]; then
        mv "$PREVIOUS_APP" "$OUTPUT_APP"
    fi
    echo "error: could not replace $OUTPUT_APP." >&2
    exit 1
fi

echo "✓ Built: $OUTPUT_APP"
echo "  Architectures: $(lipo -archs "$OUTPUT_APP/Contents/MacOS/$EXECUTABLE_NAME")"
echo "  Version: $VERSION"
echo ""
echo "To run: open \"$OUTPUT_APP\""
echo "To install: drag $PRODUCT_NAME.app into Applications."
