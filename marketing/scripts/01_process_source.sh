#!/bin/bash
# Step 1 — process the Pexels birds clip into portrait derivatives.
# Source is 2560x1440 SDR Rec.709, 29.97fps, 30s, with a fade-in (~0.85s) and a black tail (~last 1s).
# Clean window ~1.0-29.0s. We center-crop a 9:16 column (810x1440 -> scale to target), strip audio.
set -euo pipefail
cd "$(dirname "$0")/../.."

SRC="${1:-$HOME/Downloads/13456511-uhd_3840_2160_30fps.mp4}"
CROP="crop=810:1440:875:0"   # centered 9:16 column

# Preview source: ~24.5s of clean content at 1080x1920 (feeds the trail engine + the raw "before").
ffmpeg -hide_banner -loglevel error -y -ss 1.5 -t 24.5 -i "$SRC" \
  -vf "${CROP},scale=1080:1920:flags=lanczos,format=yuv420p" -an \
  -c:v libx264 -crf 18 -preset slow -movflags +faststart \
  marketing/source/birds_portrait_master.mp4

# Bundled in-app demo: short + small (720x1280, ~6s) so the bundle stays light and the demo is snappy.
ffmpeg -hide_banner -loglevel error -y -ss 7 -t 6 -i "$SRC" \
  -vf "${CROP},scale=720:1280:flags=lanczos,format=yuv420p" -an \
  -c:v libx264 -crf 20 -preset slow -movflags +faststart \
  Resources/DemoClip.mp4

echo "Wrote:"
ls -la marketing/source/birds_portrait_master.mp4 Resources/DemoClip.mp4
