#!/usr/bin/env bash
set -euo pipefail
INSTALLER="${1:?Usage: test-directmic-package.sh <DirectMic-Installer.app>}"
DRIVER="$INSTALLER/Contents/Resources/DirectMic.driver"
REQUIREMENT='=anchor apple generic and certificate leaf[subject.OU] = "52RD2GH5DP" and identifier "com.local.DirectMic.driver"'
codesign --verify --deep --strict "$INSTALLER"
codesign --verify --deep --strict -R "$REQUIREMENT" "$DRIVER"
for binary in "$INSTALLER/Contents/MacOS/DirectMicInstaller" "$DRIVER/Contents/MacOS/DirectMic"; do
    ARCHITECTURES="$(lipo -archs "$binary")"
    [[ " $ARCHITECTURES " == *" arm64 "* && " $ARCHITECTURES " == *" x86_64 "* ]]
done
# A same-team binary with another identity must never pass as the driver.
if codesign --verify --deep --strict -R "$REQUIREMENT" "$INSTALLER" 2>/dev/null; then
    echo 'FAIL: accepted a non-driver bundle' >&2; exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto "$DRIVER" "$WORK/DirectMic.driver"
printf '\ntampered\n' >> "$WORK/DirectMic.driver/Contents/Info.plist"
if codesign --verify --deep --strict -R "$REQUIREMENT" "$WORK/DirectMic.driver" 2>/dev/null; then
    echo 'FAIL: accepted a modified driver' >&2; exit 1
fi
echo 'PASS: universal signed installer and driver; wrong identity and tampered payload rejected'
