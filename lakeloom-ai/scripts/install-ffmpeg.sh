#!/bin/bash
# install-ffmpeg.sh — Downloads a static ffmpeg binary for server-side audio transcode.
#
# Usage: Called by app.yaml prestart hook or package.json prestart script.
# Purpose: Enables server-side CAF/AIFF → M4A transcode when iOS on-device
#          transcode fails (AVAssetExportSession interruption fallback).
#
# The static build is self-contained (no shared libs needed) and supports
# all codecs required for audio transcoding (pcm, alac, aac).
#
# Environment:
#   FFMPEG_PATH — override install location (default: /tmp/ffmpeg)
#
# Notes:
#   - Skips download if binary already present and executable
#   - Uses BtbN GitHub releases (trusted, maintained static builds)
#   - Only extracts the ffmpeg binary (~80 MB), not ffprobe/ffplay

set -euo pipefail

FFMPEG_DIR="${FFMPEG_PATH:-/tmp}"
FFMPEG_BIN="${FFMPEG_DIR}/ffmpeg"
FFMPEG_RELEASE_URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz"

if [ -f "$FFMPEG_BIN" ] && [ -x "$FFMPEG_BIN" ]; then
  echo "[ffmpeg] Already installed at ${FFMPEG_BIN} — skipping download"
  "${FFMPEG_BIN}" -version 2>/dev/null | head -1
  exit 0
fi

echo "[ffmpeg] Downloading static build..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -sL "$FFMPEG_RELEASE_URL" | tar xJ -C "$TEMP_DIR" --strip-components=2 --wildcards '*/bin/ffmpeg'

mv "${TEMP_DIR}/ffmpeg" "$FFMPEG_BIN"
chmod +x "$FFMPEG_BIN"

echo "[ffmpeg] Installed at ${FFMPEG_BIN}"
"${FFMPEG_BIN}" -version 2>/dev/null | head -1
