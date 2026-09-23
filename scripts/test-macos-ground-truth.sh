#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -parse-as-library \
    "$REPO_ROOT/macOS/BotSpeaker/MeetingGroundTruth.swift" \
    "$REPO_ROOT/macOS/BotSpeaker/OrchestratedMeetingTemplate.swift" \
    "$REPO_ROOT/macOS/Tests/MeetingGroundTruthTests.swift" -o "$TEST_DIR/ground-truth-tests"
"$TEST_DIR/ground-truth-tests"
