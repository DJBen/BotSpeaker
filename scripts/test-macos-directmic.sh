#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$REPO_ROOT/macOS/BotSpeaker/AudioDeviceManager.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/AudioPlaybackController.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/DirectMicPlayer.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/ElevenLabsClient.swift" \
    "$REPO_ROOT/macOS/Tests/DirectMicPlaybackTests.swift" \
    -o "$TEST_DIR/directmic-tests"
"$TEST_DIR/directmic-tests"
