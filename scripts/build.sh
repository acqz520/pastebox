#!/bin/bash
# Builds PasteBox.app into ./build. Pass --install to copy it to ~/Applications and relaunch.
# Signing with a stable identity keeps the Accessibility grant across rebuilds. By default the
# first code-signing identity in your keychain is used, falling back to ad-hoc ("-"), with
# which you have to re-grant Accessibility after every build. Override with SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/PasteBox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PasteBox "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" && \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' 'NR==1 && NF>1 {print $2}')}"
codesign --force --sign "${IDENTITY:--}" --identifier com.liuhaofeng.pastebox "$APP"
echo "signed with ${IDENTITY:--}"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x PasteBox || true
    rm -rf "$DEST/PasteBox.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/PasteBox.app"
    echo "installed $DEST/PasteBox.app"
fi
