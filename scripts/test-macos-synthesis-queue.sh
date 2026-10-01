#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$REPO_ROOT/macOS/BotSpeaker/ElevenLabsClient.swift" \
    "$REPO_ROOT/macOS/Tests/SynthesisQueueTests.swift" \
    -o "$TEST_DIR/synthesis-queue-tests"
"$TEST_DIR/synthesis-queue-tests"
