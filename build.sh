#!/bin/bash
set -e

echo "Building InternetSpeed..."
swift build -c release

# Create app bundle
APP_DIR="InternetSpeed.app/Contents/MacOS"
mkdir -p "$APP_DIR"
cp .build/release/InternetSpeed "$APP_DIR/"

# Create Info.plist
cat > InternetSpeed.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>InternetSpeed</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.internetspeed</string>
    <key>CFBundleName</key>
    <string>InternetSpeed</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "✓ Built: InternetSpeed.app"
echo ""
echo "To run: open InternetSpeed.app"
echo "To install: cp -r InternetSpeed.app /Applications/"
