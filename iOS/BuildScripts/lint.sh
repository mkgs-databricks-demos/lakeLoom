#!/usr/bin/env bash
# lint.sh — runs SwiftLint and swift-format on the App / AppTests / AppUITests trees.
# Used by `make lint` and (optionally) by a pre-commit hook.

set -euo pipefail

# Locate the iOS root (the directory containing this script's parent).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$IOS_ROOT"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint not found. Run \`make setup\` (or \`brew install swiftlint\`) first." >&2
  exit 1
fi

if ! command -v swift-format >/dev/null 2>&1; then
  echo "swift-format not found. Run \`make setup\` (or \`brew install swift-format\`) first." >&2
  exit 1
fi

echo "▸ swift-format lint"
swift-format lint --recursive --strict --configuration .swift-format App AppTests AppUITests

echo "▸ swiftlint"
swiftlint lint --strict --quiet

echo "✓ lint clean"
