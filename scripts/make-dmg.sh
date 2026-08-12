#!/usr/bin/env bash

set -euo pipefail

APP_PATH="${1:?Usage: $0 <App.app> <output.dmg> [signing-identity]}"
OUTPUT_DMG="${2:?Usage: $0 <App.app> <output.dmg> [signing-identity]}"
SIGNING_IDENTITY="${3:-}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: app bundle not found: $APP_PATH" >&2
    exit 1
fi

if [[ "$OUTPUT_DMG" != *.dmg ]]; then
    echo "Error: output path must end in .dmg" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "Error: create-dmg is not installed." >&2
    echo "Install it with: npm install --global create-dmg" >&2
    exit 1
fi

OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DMG")" && pwd)"
OUTPUT_DMG="$OUTPUT_DIR/$(basename "$OUTPUT_DMG")"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

CREATE_DMG_ARGUMENTS=()
if [[ -n "$SIGNING_IDENTITY" ]]; then
    CREATE_DMG_ARGUMENTS+=("--identity=$SIGNING_IDENTITY")
else
    CREATE_DMG_ARGUMENTS+=(--no-code-sign)
fi

create-dmg "${CREATE_DMG_ARGUMENTS[@]}" "$APP_PATH" "$WORK_DIR"

GENERATED_DMG="$(find "$WORK_DIR" -maxdepth 1 -type f -name '*.dmg' -print -quit)"
if [[ -z "$GENERATED_DMG" ]]; then
    echo "Error: create-dmg did not produce a disk image" >&2
    exit 1
fi

mv "$GENERATED_DMG" "$OUTPUT_DMG"
echo "Created $OUTPUT_DMG"
