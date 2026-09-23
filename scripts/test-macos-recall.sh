#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$REPO_ROOT/macOS/BotSpeaker/RecallController.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/RecallMeetingInput.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/RecallRunManager.swift" \
    "$REPO_ROOT/macOS/Tests/RecallTests.swift" -o "$TEST_DIR/recall-tests"
"$TEST_DIR/recall-tests" "$REPO_ROOT/macOS/BotSpeaker/recall-silence.mp3"
swift build --package-path "$REPO_ROOT/cli" >/dev/null
CLI_DIR="$(swift build --package-path "$REPO_ROOT/cli" --show-bin-path)"
python3 "$REPO_ROOT/macOS/Tests/RecallCLITests.py" "$CLI_DIR/botspeaker"
