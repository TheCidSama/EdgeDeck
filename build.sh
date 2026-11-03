#!/bin/bash
# Builds build/EdgeDeck.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/EdgeDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EdgeDeck "$APP/Contents/MacOS/EdgeDeck"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP"
