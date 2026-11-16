#!/bin/sh
# Builds "PCB Assembly Guide.app" into ./build using only the Swift toolchain (no Xcode needed).
# Pass "install" to also copy it into /Applications.
set -e
cd "$(dirname "$0")"
swift build -c release
BIN=.build/release/PCBAssemblyGuide
APP="build/PCB Assembly Guide.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp -R Resources/web "$APP/Contents/Resources/web"

# The app draws its own icon; turn that into the sizes macOS wants.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
"$BIN" --icon build/icon-1024.png
for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
if [ "$1" = "install" ]; then
    rm -rf "/Applications/PCB Assembly Guide.app"
    cp -R "$APP" /Applications/
    echo "Installed to /Applications"
fi
