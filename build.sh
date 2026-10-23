#!/bin/bash
# Build Vox.app: swift build -> assemble the .app bundle -> ad-hoc sign
#   ./build.sh            build and package
#   ./build.sh run        build, then open the app
#   ./build.sh selftest   run the headless self-test only (verifies the model path)
set -euo pipefail
cd "$(dirname "$0")"

APP="Vox.app"
BIN=".build/release/VoxApp"

echo "==> swift build -c release"
swift build -c release 2>&1 | tail -20

if [ "${1:-}" = "selftest" ]; then
  echo "==> selftest"
  "$BIN" --selftest
  exit $?
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoxApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Localized bundle strings (InfoPlist.strings) used by the system dialogs — one directory per language.
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

echo "==> ad-hoc signing (TCC needs a stable identity)"
codesign --force --deep --sign - --identifier app.voxdictation.mac "$APP" 2>&1 | tail -3

echo "==> done: $(pwd)/$APP"
if [ "${1:-}" = "run" ]; then
  open "$APP"
fi
