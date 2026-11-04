#!/bin/bash
# Step 2b — the extra engine renders behind the sunset hero, the Effects screenshot and the
# "white birds on blue" variety shot. Real engine output, like 02_render_trails.sh.
#
#   build/sunset_birds_2x_trail.mp4   sunset geese, natural silhouettes (hero of the preview video
#                                     and screenshots 01–03)
#   build/birds_gradient_trail.mp4    grey-sky flock with the AGE GRADIENT (orange → blue) and a
#                                     2 s fade — 04_screenshots.py switches 05_effects to this
#                                     render (and shows the Colour controls in the gradient state)
#                                     as soon as it exists
#   build/storks_trail.mp4            white storks on blue sky, contrast=highlight — optional
#                                     variety still (storks_9.png) for a future screenshot/beat
#
# Compiles the promo harness first (Engine sources + harness/promo/main.swift only).
set -euo pipefail
cd "$(dirname "$0")/../.."

swiftc -swift-version 5 Sources/Engine/*.swift harness/promo/main.swift -o /tmp/promorender

mkdir -p marketing/build

/tmp/promorender marketing/source/sunset_geese_master.mp4 marketing/build/sunset_birds_2x_trail.mp4 \
  contrast=silhouette horizon=0.25 freq=0.8 fade=0 bg=frozen maxdim=1920

/tmp/promorender marketing/source/birds_portrait_master.mp4 marketing/build/birds_gradient_trail.mp4 \
  contrast=silhouette horizon=0.25 freq=0.8 fade=2 bg=frozen maxdim=1920 color=gradient shift=3

if [ -f marketing/source/storks_master.mp4 ]; then
  /tmp/promorender marketing/source/storks_master.mp4 marketing/build/storks_trail.mp4 \
    contrast=highlight horizon=0.25 freq=0.8 fade=0 bg=frozen maxdim=1920
fi

for f in marketing/build/sunset_birds_2x_trail.mp4 marketing/build/birds_gradient_trail.mp4 marketing/build/storks_trail.mp4; do
  [ -f "$f" ] && ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,nb_frames,duration -of default=noprint_wrappers=1 "$f" && echo "  ^ $f"
done
# Re-cut the stills the screenshots use from these renders (04 only cuts missing PNGs).
rm -f marketing/work/stills/gradient_14.png marketing/work/stills/storks_9.png
echo "Now: python3 marketing/scripts/04_screenshots.py && python3 marketing/scripts/04b_screenshots_ipad.py"
