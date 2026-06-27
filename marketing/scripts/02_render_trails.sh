#!/bin/bash
# Step 2 — render the trail effect with the real engine (the app's own output, not an approximation).
# Settings: natural dark silhouettes over a frozen plate — ideal for dark birds on a bright sky.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Compile the promo harness (Engine sources + this harness only; NOT harness/main.swift).
swiftc -swift-version 5 Sources/Engine/*.swift harness/promo/main.swift -o /tmp/promorender

/tmp/promorender \
  marketing/source/birds_portrait_master.mp4 \
  marketing/build/birds_trail.mp4 \
  contrast=silhouette horizon=0.25 freq=0.8 fade=0 bg=frozen maxdim=1920

ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,nb_frames,duration -of default=noprint_wrappers=1 \
  marketing/build/birds_trail.mp4
