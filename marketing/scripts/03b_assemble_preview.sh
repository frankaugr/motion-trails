#!/bin/bash
# Step 3b — assemble the App Store preview: raw "before" -> trail "after" -> branded endcard.
# 1080x1920, ~23s (Apple requires 15-30s), H.264, with a silent AAC track for clean ingestion.
set -euo pipefail
cd "$(dirname "$0")/../.."
W=marketing/work
RAW=marketing/source/birds_portrait_master.mp4
TRAIL=marketing/build/birds_trail.mp4
OUT=marketing/preview/MotionTrails-Preview-6.7.mp4
V="fps=30,scale=1080:1920,setsar=1,format=yuv420p"

# Segment A — raw intro (3.5s) with the "before" caption.
ffmpeg -hide_banner -loglevel error -y -ss 0 -t 3.5 -i "$RAW" -loop 1 -t 3.5 -i "$W/cap_intro.png" \
  -filter_complex "[0:v]${V}[bg];[1:v]format=rgba,fade=t=in:st=0.3:d=0.4:alpha=1,fade=t=out:st=2.9:d=0.4:alpha=1[c];[bg][c]overlay=0:0[v]" \
  -map "[v]" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 "$W/seg_a.mp4"

# Segment B — trail build (18s) with the "after" caption appearing as trails start to form.
ffmpeg -hide_banner -loglevel error -y -ss 0 -t 18 -i "$TRAIL" -loop 1 -t 18 -i "$W/cap_build.png" \
  -filter_complex "[0:v]${V}[bg];[1:v]format=rgba,fade=t=in:st=1.2:d=0.5:alpha=1,fade=t=out:st=5.0:d=0.6:alpha=1[c];[bg][c]overlay=0:0[v]" \
  -map "[v]" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 "$W/seg_b.mp4"

# Segment C — branded endcard (3s).
ffmpeg -hide_banner -loglevel error -y -loop 1 -t 3 -i "$W/endcard.png" \
  -filter_complex "[0:v]${V}[v]" -map "[v]" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 "$W/seg_c.mp4"

# Crossfade the three, add a silent stereo track.
ffmpeg -hide_banner -loglevel error -y -i "$W/seg_a.mp4" -i "$W/seg_b.mp4" -i "$W/seg_c.mp4" \
  -f lavfi -t 30 -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter_complex "[0:v][1:v]xfade=transition=fade:duration=0.6:offset=2.9[ab];[ab][2:v]xfade=transition=fade:duration=0.7:offset=20.2[v]" \
  -map "[v]" -map 3:a -shortest \
  -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 -c:a aac -b:a 128k -movflags +faststart "$OUT"

ffprobe -v error -show_entries format=duration -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
  -of default=noprint_wrappers=1 "$OUT"
echo "Wrote $OUT"; ls -la "$OUT"
