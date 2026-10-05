#!/bin/bash
# Build SnatchMac.app.
#   ./build.sh install   also copies it to ~/Applications and relaunches it
#   ./build.sh dmg       also packs build/SnatchMac-<version>.dmg (drag-to-Applications)
set -euo pipefail
cd "$(dirname "$0")"

# Universal binary: Apple Silicon + Intel.
swift build -c release --triple arm64-apple-macosx14.0
swift build -c release --triple x86_64-apple-macosx14.0
BIN=.build/SnatchMac-universal
lipo -create -output "$BIN" \
  .build/arm64-apple-macosx/release/SnatchMac \
  .build/x86_64-apple-macosx/release/SnatchMac

APP=build/SnatchMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SnatchMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Screen Recording permission is tied to the signature. A stable self-signed identity keeps it
# across rebuilds; ad-hoc signing changes every build, so macOS asks again each time.
SIGN_ID="${SNATCHMAC_SIGN_ID:-SnatchMac Dev}"
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign --force --options runtime --sign "$SIGN_ID" "$APP"
  echo "Signed with \"$SIGN_ID\""
else
  codesign --force --sign - "$APP"
  echo "⚠️  No \"$SIGN_ID\" code-signing identity found, signed ad-hoc."
  echo "   Screen Recording permission will reset on every rebuild until you create one (see README)."
fi

if [[ "${1:-}" == "dmg" ]]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  DMG="build/SnatchMac-$VERSION.dmg"
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  # Volume icon: .VolumeIcon.icns plus the "has custom icon" flag on the volume root.
  cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
  rm -f "$DMG"
  RW=$(mktemp -u).dmg
  hdiutil create -quiet -volname "SnatchMac" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
  MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
  SetFile -a C "$MOUNT" 2>/dev/null || true
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
  rm -rf "$STAGE" "$RW"
  if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" "$DMG"
  fi
  echo "Built $DMG ($(du -h "$DMG" | cut -f1 | xargs))"
elif [[ "${1:-}" == "install" ]]; then
  # Always ~/Applications: macOS App Management blocks terminals from modifying /Applications.
  DEST=~/Applications
  if [[ -d /Applications/SnatchMac.app ]]; then
    echo "⚠️  /Applications/SnatchMac.app exists (a DMG install). Delete it in Finder to avoid two copies."
  fi
  pkill -x SnatchMac 2>/dev/null || true
  mkdir -p "$DEST"
  rm -rf "$DEST/SnatchMac.app"
  cp -R "$APP" "$DEST/"
  open "$DEST/SnatchMac.app"
  echo "Installed to $DEST/SnatchMac.app"
else
  echo "Built $APP"
fi
