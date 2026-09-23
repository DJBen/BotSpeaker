#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$REPO_ROOT/macOS/BotSpeaker/VoiceSelection.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/ElevenLabsClient.swift" \
    "$REPO_ROOT/macOS/Tests/VoiceSelectionTests.swift" \
    -o "$TEST_DIR/voice-tests"
"$TEST_DIR/voice-tests"
swift build --package-path "$REPO_ROOT/cli" >/dev/null
CLI_DIR="$(swift build --package-path "$REPO_ROOT/cli" --show-bin-path)"
python3 "$REPO_ROOT/macOS/Tests/VoiceCLITests.py" "$CLI_DIR/botspeaker"
