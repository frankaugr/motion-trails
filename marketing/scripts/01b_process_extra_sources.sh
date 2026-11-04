#!/bin/bash
# Step 1b — process the two extra Pexels clips into portrait masters for the engine.
#
#   Sunset geese  — Pexels video 14515019 (1080x1920, 24 fps, 20.75 s). Sped up 2x and conformed
#                   to 30 fps: the geese stream in slowly at native speed, and 2x gives the trail
#                   a clean ribbon in a 10 s render. → marketing/source/sunset_geese_master.mp4
#   White storks  — Pexels video 13313562 (1080x1920, 60 fps, 11.65 s). Conformed to 30 fps (the
#                   engine's temporal horizon is in seconds, so the frame rate only sets the delay-
#                   line length). Bright birds on a blue sky — the "Highlight"/"Any" contrast case,
#                   a different look from the two dark-silhouette clips. → storks_master.mp4
#
# Both are Pexels License (free commercial use, modification allowed, no attribution required) —
# see marketing/README.md. Download the originals from pexels.com/video/<id>/ into ~/Downloads
# (the filenames below are Pexels' own download names) or pass the paths as $1 / $2.
set -euo pipefail
cd "$(dirname "$0")/../.."

GEESE="${1:-$HOME/Downloads/14515019_1080_1920_24fps.mp4}"
STORKS="${2:-$HOME/Downloads/13313562_1080_1920_60fps.mp4}"

if [ -f "$GEESE" ]; then
  ffmpeg -hide_banner -loglevel error -y -i "$GEESE" \
    -vf "setpts=0.5*PTS,fps=30,scale=1080:1920:flags=lanczos,format=yuv420p" -an \
    -c:v libx264 -crf 18 -preset slow -movflags +faststart \
    marketing/source/sunset_geese_master.mp4
  echo "wrote marketing/source/sunset_geese_master.mp4"
else
  echo "skip geese: $GEESE not found (marketing/source/sunset_geese_master.mp4 is already committed)"
fi

if [ -f "$STORKS" ]; then
  ffmpeg -hide_banner -loglevel error -y -i "$STORKS" \
    -vf "fps=30,scale=1080:1920:flags=lanczos,format=yuv420p" -an \
    -c:v libx264 -crf 18 -preset slow -movflags +faststart \
    marketing/source/storks_master.mp4
  echo "wrote marketing/source/storks_master.mp4"
else
  echo "skip storks: $STORKS not found"
fi
