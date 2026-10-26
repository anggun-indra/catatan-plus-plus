#!/bin/bash
# Build Notepad++ for macOS from the upstream source tree.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
APP_NAME="Catatan++"
BUILD="$HERE/build"
DIST="$HERE/dist"
SDK="$(xcrun --show-sdk-path)"

SCINTILLA="$SRC/scintilla"
LEXILLA="$SRC/lexilla"

CXXFLAGS=(
  -std=c++17 -fobjc-arc -O2 -DNDEBUG
  -mmacosx-version-min=11.0
  -isysroot "$SDK"
  "-I$SCINTILLA/include" "-I$SCINTILLA/src" "-I$SCINTILLA/cocoa"
  "-I$LEXILLA/include" "-I$LEXILLA/lexlib"
  "-I$HERE/shim" "-I$HERE/src"
  -Wno-everything
)

CLEAN=0
if [ "${1:-}" = "--clean" ] || [ "${1:-}" = "-c" ]; then
  CLEAN=1
  rm -rf "$BUILD"
fi
mkdir -p "$BUILD/sci" "$BUILD/lex" "$BUILD/app" "$DIST"

if [ "$CLEAN" -eq 1 ] || [ $(ls "$BUILD/sci"/*.o 2>/dev/null | wc -l) -lt 30 ]; then
  echo "==> Building Scintilla core"
  for f in "$SCINTILLA"/src/*.cxx; do
    clang++ "${CXXFLAGS[@]}" -c "$f" -o "$BUILD/sci/$(basename "$f" .cxx).o"
  done
else
  echo "==> Scintilla core cached ($(ls "$BUILD/sci"/*.o | wc -l | tr -d ' ') objects)"
fi

if [ "$CLEAN" -eq 1 ] || [ $(ls "$BUILD/sci"/*Cocoa*.o 2>/dev/null | wc -l) -lt 1 ]; then
  echo "==> Building Scintilla Cocoa layer"
  for f in "$SCINTILLA"/cocoa/*.mm; do
    clang++ "${CXXFLAGS[@]}" -c "$f" -o "$BUILD/sci/$(basename "$f" .mm).o"
  done
else
  echo "==> Scintilla Cocoa cached"
fi

if [ "$CLEAN" -eq 1 ] || [ $(ls "$BUILD/lex"/*.o 2>/dev/null | wc -l) -lt 130 ]; then
  echo "==> Building Lexilla lexers"
  for f in "$LEXILLA"/lexlib/*.cxx "$LEXILLA"/lexers/*.cxx "$LEXILLA"/src/*.cxx; do
    clang++ "${CXXFLAGS[@]}" -c "$f" -o "$BUILD/lex/$(basename "$f" .cxx).o"
  done
else
  echo "==> Lexilla lexers cached ($(ls "$BUILD/lex"/*.o | wc -l | tr -d ' ') objects)"
fi

echo "==> Building application"
for f in "$HERE"/src/*.m "$HERE"/src/*.mm; do
  [ -e "$f" ] || continue
  clang++ "${CXXFLAGS[@]}" -x objective-c++ -c "$f" -o "$BUILD/app/$(basename "${f%.*}").o"
done
for f in "$HERE"/src/*.c; do
  [ -e "$f" ] || continue
  clang "${CXXFLAGS[@]/#-std=c++17/-std=c11}" -c "$f" -o "$BUILD/app/$(basename "${f%.*}").o"
done

echo "==> Linking"
clang++ -o "$BUILD/$APP_NAME" "$BUILD"/app/*.o "$BUILD"/sci/*.o "$BUILD"/lex/*.o \
  -isysroot "$SDK" -mmacosx-version-min=11.0 \
  -framework Cocoa -framework QuartzCore -framework CoreText -framework Foundation -framework WebKit

echo "==> Assembling bundle"
BUNDLE="$DIST/$APP_NAME.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"

echo "==> Copying toolbar icons and app icon"
mkdir -p "$BUNDLE/Contents/Resources/icons"
cp "$HERE"/icons/*.svg "$BUNDLE/Contents/Resources/icons/"
[ -f "$HERE/icons/AppIcon.icns" ] && cp "$HERE/icons/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
echo "    $(ls "$BUNDLE/Contents/Resources/icons" | wc -l | tr -d ' ') toolbar icons"

echo "==> Copying preview assets"
mkdir -p "$BUNDLE/Contents/Resources/preview"
cp -R "$HERE"/resources/preview/* "$BUNDLE/Contents/Resources/preview/"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Catatan++</string>
  <key>CFBundleDisplayName</key><string>catatan++</string>
  <key>CFBundleIdentifier</key><string>io.github.anggun-indra.catatan-plus-plus</string>
  <key>CFBundleExecutable</key><string>Catatan++</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Text Document</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.text</string>
        <string>public.plain-text</string>
        <string>public.utf8-plain-text</string>
        <string>public.source-code</string>
        <string>public.script</string>
        <string>public.data</string>
        <string>public.content</string>
        <string>public.item</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>All Files</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeIconFile</key><string>AppIcon</string>
      <key>CFBundleTypeOSTypes</key>
      <array>
        <string>TEXT</string>
        <string>utxt</string>
        <string>TUTX</string>
        <string>****</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>*</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$BUNDLE" 2>/dev/null || true

echo "==> Done: $BUNDLE"
