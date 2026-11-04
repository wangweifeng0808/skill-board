#!/usr/bin/env bash
# Build SkillBar.app (a menu bar shell around the dashboard) and launch it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
APP="$HOME/Applications/SkillBar.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

echo "==> compiling"
swiftc -O -o "$HERE/SkillBar" "$HERE/SkillBar.swift"

echo "==> packaging $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/SkillBar" "$APP/Contents/MacOS/SkillBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SkillBar</string>
  <key>CFBundleDisplayName</key><string>Skill Board</string>
  <key>CFBundleIdentifier</key><string>com.skillboard.skillbar</string>
  <key>CFBundleExecutable</key><string>SkillBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> installed: $APP"
echo "    project dir: $ROOT"

open "$APP"
echo "==> launched (look for the stacked-squares icon in the menu bar)"
