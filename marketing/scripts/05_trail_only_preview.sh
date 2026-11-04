#!/bin/bash
# Step 5 — alternative App Store preview: the FULL trail render with marketing captions on top,
# closing on the branded endcard (no "before" segment — the trail footage carries the whole video).
# 886x1920 (App Store Connect requires exactly 886x1920 / 1920x886 for the iPhone preview slots —
# 1080x1920 is REJECTED at upload; overlays are composed at 1080 and center-cropped, everything is
# centered well inside the crop), ~26.8s (Apple requires 15-30s), H.264, silent AAC for ingestion.
# Caption copy mirrors marketing/appstore-metadata.md (tagline, live-tuning bullet, everything-
# included promise — the app is paid up-front with no IAP, so don't say "free" here).
set -uo pipefail
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
S=marketing/scripts
W=marketing/work
TRAIL=marketing/build/birds_trail.mp4
OUT=marketing/preview/MotionTrails-Preview-Trail-886x1920.mp4
PROFILE="$(mktemp -d)"
# `|| true`: set -e is active by assembly time, and pkill "fails" when Chrome already exited.
trap 'pkill -9 -f "$PROFILE" 2>/dev/null || true; rm -rf "$PROFILE"' EXIT

shoot(){ # html, out.png, w, h, extra-flags
  rm -f "$2"
  "$CHROME" --headless=new --disable-gpu --no-first-run --no-default-browser-check \
    --user-data-dir="$PROFILE" --allow-file-access-from-files \
    --force-device-scale-factor=1 --window-size="$3,$4" --hide-scrollbars \
    ${5:-} --screenshot="$2" "file://$(pwd)/$1" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 50); do [ -s "$2" ] && { sleep 0.5; break; }; sleep 0.4; done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

# Four timed captions over the trail build (endcard.png must already exist — run 03a first).
sed "s#REPLACE_TEXT#Turn motion into trails#"           "$S/caption.html" > "$W/cap_t1.html"
sed "s#REPLACE_TEXT#Every pass becomes a trail#"        "$S/caption.html" > "$W/cap_t2.html"
sed "s#REPLACE_TEXT#Tune density, fade and colour#"     "$S/caption.html" > "$W/cap_t3.html"
sed "s#REPLACE_TEXT#Every effect included<br>No in-app purchases#" "$S/caption.html" > "$W/cap_t4.html"
for i in 1 2 3 4; do
  shoot "$W/cap_t$i.html" "$W/cap_t$i.png" 1080 1920 "--default-background-color=00000000"
done

set -e
for f in "$W"/cap_t{1,2,3,4}.png "$W/endcard.png" "$TRAIL"; do
  [ -s "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

# Scale to 1920 tall, then center-crop the width to the ASC-mandated 886.
V="fps=30,scale=-2:1920,crop=886:1920,setsar=1,format=yuv420p"
DUR=24.6   # birds_trail.mp4 is 24.53s; -loop image inputs just need to outlast it

# Main segment — the whole trail render, four captions fading through in sequence.
ffmpeg -hide_banner -loglevel error -y -i "$TRAIL" \
  -loop 1 -t "$DUR" -i "$W/cap_t1.png" -loop 1 -t "$DUR" -i "$W/cap_t2.png" \
  -loop 1 -t "$DUR" -i "$W/cap_t3.png" -loop 1 -t "$DUR" -i "$W/cap_t4.png" \
  -filter_complex "\
[0:v]${V}[bg];\
[1:v]format=rgba,crop=886:1920,fade=t=in:st=0.4:d=0.45:alpha=1,fade=t=out:st=4.2:d=0.5:alpha=1[c1];\
[2:v]format=rgba,crop=886:1920,fade=t=in:st=6.0:d=0.45:alpha=1,fade=t=out:st=9.8:d=0.5:alpha=1[c2];\
[3:v]format=rgba,crop=886:1920,fade=t=in:st=12.0:d=0.45:alpha=1,fade=t=out:st=15.8:d=0.5:alpha=1[c3];\
[4:v]format=rgba,crop=886:1920,fade=t=in:st=18.0:d=0.45:alpha=1,fade=t=out:st=21.9:d=0.5:alpha=1[c4];\
[bg][c1]overlay=0:0[v1];[v1][c2]overlay=0:0[v2];[v2][c3]overlay=0:0[v3];[v3][c4]overlay=0:0[v]" \
  -map "[v]" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 "$W/seg_trail_main.mp4"

# Endcard segment (3s).
ffmpeg -hide_banner -loglevel error -y -loop 1 -t 3 -i "$W/endcard.png" \
  -filter_complex "[0:v]${V}[v]" -map "[v]" -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 "$W/seg_trail_end.mp4"

# Crossfade into the endcard, add a silent stereo track.
ffmpeg -hide_banner -loglevel error -y -i "$W/seg_trail_main.mp4" -i "$W/seg_trail_end.mp4" \
  -f lavfi -t 30 -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter_complex "[0:v][1:v]xfade=transition=fade:duration=0.7:offset=23.8[v]" \
  -map "[v]" -map 2:a -shortest \
  -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 -c:a aac -b:a 128k -movflags +faststart "$OUT"

ffprobe -v error -show_entries format=duration -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
  -of default=noprint_wrappers=1 "$OUT"
echo "Wrote $OUT"; ls -la "$OUT"
