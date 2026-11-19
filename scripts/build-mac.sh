#!/bin/zsh
# Builds build/done.app (ad-hoc signed, for this Mac).
set -euo pipefail
ROOT=${0:A:h:h}
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

swift "$ROOT/scripts/make-icons.swift" "$ROOT"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"

cd "$ROOT/mac"
swift build -c release --product Todo
BIN="$(swift build -c release --show-bin-path)/Todo"

APP="$ROOT/build/done.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/done"
cp "$ROOT/mac/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/mac/Resources/Fonts" "$APP/Contents/Resources/Fonts"   # Hahmlet (OFL), loaded via ATSApplicationFontsPath
codesign --force --sign - "$APP"
echo "built $APP"
