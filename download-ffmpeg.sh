#!/bin/bash
# download-ffmpeg.sh
# Downloads a static ffmpeg build for macOS and places it in the Xcode Resources folder.
# Run once from the repo root, then add the binary to your Xcode target:
#   Xcode → PromptCut target → Build Phases → Copy Bundle Resources → + → Resources/ffmpeg

set -e

DEST="$(dirname "$0")/PromptCut/PromptCut/Resources/ffmpeg"
mkdir -p "$(dirname "$DEST")"

if [ -f "$DEST" ]; then
  echo "ffmpeg already present at $DEST — skipping download."
  exit 0
fi

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"

TMP=$(mktemp -d)
ZIP="$TMP/ffmpeg.zip"

# evermeet.cx provides notarized static builds for macOS (arm64 + x86_64)
echo "Downloading ffmpeg from evermeet.cx…"
curl -L --progress-bar "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip" -o "$ZIP"

echo "Extracting…"
unzip -q "$ZIP" -d "$TMP"

BINARY=$(find "$TMP" -name "ffmpeg" -type f | head -1)
if [ -z "$BINARY" ]; then
  echo "ERROR: ffmpeg binary not found in archive." >&2
  exit 1
fi

cp "$BINARY" "$DEST"
chmod +x "$DEST"
rm -rf "$TMP"

echo ""
echo "✓ ffmpeg downloaded to: $DEST"
echo ""
echo "Next step in Xcode:"
echo "  PromptCut target → Build Phases → Copy Bundle Resources → (+) → PromptCut/Resources/ffmpeg"
