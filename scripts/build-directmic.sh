#!/usr/bin/env bash
set -euo pipefail
# The private source checkout is needed only on the release machine.
SOURCE="${1:?Usage: build-directmic.sh <DirectMic-source> <output-installer-app> <signing-identity>}"
INSTALLER="${2:?Missing output path}"
OUTPUT="$INSTALLER/Contents/Resources/DirectMic.driver"
IDENTITY="${3:?Missing signing identity}"
[[ "$(git -C "$SOURCE/vendor/libASPL" rev-parse HEAD)" == "633e0f70203edd87d320fc5a3cae901e1363aac5" ]] || { echo 'Unexpected libASPL revision.' >&2; exit 1; }
[[ -f "$SOURCE/Driver.cpp" && -d "$SOURCE/vendor/libASPL/include" ]] || { echo 'DirectMic source and libASPL checkout are required.' >&2; exit 1; }
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources"
cp "$SOURCE/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$SOURCE/vendor/libASPL/"LICENSE* "$OUTPUT/Contents/Resources/"
clang++ -std=c++17 -O2 -fPIC -bundle -arch arm64 -arch x86_64 \
    -mmacosx-version-min=14.0 -I"$SOURCE/vendor/libASPL/include" \
    "$SOURCE/Driver.cpp" "$SOURCE"/vendor/libASPL/src/*.cpp \
    -framework CoreAudio -framework CoreFoundation \
    -o "$OUTPUT/Contents/MacOS/DirectMic"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$OUTPUT"
codesign --verify --strict "$OUTPUT"
ARCHITECTURES="$(lipo -archs "$OUTPUT/Contents/MacOS/DirectMic")"
[[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]] || { echo "Expected universal DirectMic driver, found $ARCHITECTURES" >&2; exit 1; }

mkdir -p "$INSTALLER/Contents/MacOS"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for arch in arm64 x86_64; do
    swiftc -swift-version 5 -O -target "$arch-apple-macos14.0" \
        "$SCRIPT_DIR/DirectMicInstaller.swift" -o "$BUILD_DIR/installer-$arch"
done
lipo -create "$BUILD_DIR/installer-arm64" "$BUILD_DIR/installer-x86_64" \
    -output "$INSTALLER/Contents/MacOS/DirectMicInstaller"
cat > "$INSTALLER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.botspeaker.DirectMicInstaller</string>
<key>CFBundleName</key><string>DirectMic Installer</string>
<key>CFBundleExecutable</key><string>DirectMicInstaller</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$INSTALLER"
codesign --verify --deep --strict "$INSTALLER"
