#!/bin/bash
# Step 6 — the App Store preview video, i.e. the HERO of the listing (it autoplays before the
# screenshots on the product page and in search). Four beats, all real engine output:
#
#   A  sunset geese trail blooming in (build/sunset_birds_2x_trail.mp4, from 3.4 s)   ~7.0 s
#   B  the editor — "tune it live" (work/preview_editor.html from 04_screenshots.py)  ~2.8 s
#   C  the grey-sky flock filling the frame (build/birds_trail.mp4, 6–16 s)            ~10 s
#   D  branded endcard (work/endcard.png from 03a)                                      3 s
#
# 886x1920 (App Store Connect requires exactly 886x1920 / 1920x886 for iPhone preview slots —
# 1080x1920 is REJECTED at upload; overlays are composed at 1080 and centre-cropped), ~21.0 s
# (Apple: 15–30 s), H.264, silent AAC track for ingestion. Poster frame suggestion: ~5.5 s.
# Caption copy mirrors marketing/appstore-metadata.md — the app is paid up-front with no IAP,
# so never "free" here.
set -uo pipefail
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
S=marketing/scripts
W=marketing/work
SUNSET=marketing/build/sunset_birds_2x_trail.mp4
BIRDS=marketing/build/birds_trail.mp4
OUT=marketing/preview/MotionTrails-Preview-Hero-886x1920.mp4
PROFILE="$(mktemp -d)"
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

# Bottom captions (transparent) — one per beat.
sed "s#REPLACE_TEXT#Turn motion into trails#"                            "$S/caption.html" > "$W/hcap_1.html"
sed "s#REPLACE_TEXT#Every pass becomes a trail#"                         "$S/caption.html" > "$W/hcap_2.html"
sed "s#REPLACE_TEXT#Birds · cyclists · traffic · waves#"                 "$S/caption.html" > "$W/hcap_3.html"
sed "s#REPLACE_TEXT#Every effect included<br>No in-app purchases#"       "$S/caption.html" > "$W/hcap_4.html"
for i in 1 2 3 4; do
  shoot "$W/hcap_$i.html" "$W/hcap_$i.png" 1080 1920 "--default-background-color=00000000"
done
# Top caption for the editor beat (the chrome owns the bottom of that frame).
sed -e "s#REPLACE_TEXT#Tune it live#" \
    -e "s#bottom:560px#top:0;height:640px#" \
    -e "s#to top, rgba(8,9,11,.78) 0%, rgba(8,9,11,.5) 40%, rgba(8,9,11,0) 100%#to bottom, rgba(8,9,11,.78) 0%, rgba(8,9,11,.5) 40%, rgba(8,9,11,0) 100%#" \
    -e "s#bottom:250px#top:300px#" "$S/caption.html" > "$W/hcap_top.html"
shoot "$W/hcap_top.html" "$W/hcap_top.png" 1080 1920 "--default-background-color=00000000"
# Editor beat (opaque) and endcard (regenerate if 03a hasn't run).
shoot "$W/preview_editor.html" "$W/preview_editor.png" 1080 1920
if [ ! -s "$W/endcard.png" ]; then
  cp Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png "$W/icon.png"
  sed "s#REPLACE_ICON#file://$(pwd)/$W/icon.png#" "$S/endcard.html" > "$W/endcard.filled.html"
  shoot "$W/endcard.filled.html" "$W/endcard.png" 1080 1920
fi

set -e
for f in "$W"/hcap_{1,2,3,4,top}.png "$W/preview_editor.png" "$W/endcard.png" "$SUNSET" "$BIRDS"; do
  [ -s "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

V="fps=30,scale=-2:1920,crop=886:1920,setsar=1,format=yuv420p"
ENC=(-c:v libx264 -crf 16 -pix_fmt yuv420p -r 30 -video_track_timescale 30000)

# A — sunset trail from 3.4 s to the end (7.0 s): the ribbon is already visible on frame one.
ffmpeg -hide_banner -loglevel error -y -ss 3.4 -t 7.0 -i "$SUNSET" \
  -loop 1 -t 7.0 -i "$W/hcap_1.png" -loop 1 -t 7.0 -i "$W/hcap_2.png" \
  -filter_complex "\
[0:v]${V}[bg];\
[1:v]format=rgba,crop=886:1920,fade=t=in:st=0.3:d=0.45:alpha=1,fade=t=out:st=2.9:d=0.45:alpha=1[c1];\
[2:v]format=rgba,crop=886:1920,fade=t=in:st=3.4:d=0.45:alpha=1,fade=t=out:st=5.8:d=0.5:alpha=1[c2];\
[bg][c1]overlay=0:0[v1];[v1][c2]overlay=0:0[v]" \
  -map "[v]" "${ENC[@]}" -t 7.0 "$W/hseg_a.mp4"

# B — editor still with a slow push-in (84 frames = 2.8 s) + top caption.
ffmpeg -hide_banner -loglevel error -y -i "$W/preview_editor.png" -loop 1 -t 2.8 -i "$W/hcap_top.png" \
  -filter_complex "\
[0:v]zoompan=z='1+0.035*on/84':d=84:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1080x1920:fps=30,${V}[bg];\
[1:v]format=rgba,crop=886:1920,fade=t=in:st=0.25:d=0.4:alpha=1,fade=t=out:st=2.2:d=0.4:alpha=1[c];\
[bg][c]overlay=0:0[v]" \
  -map "[v]" "${ENC[@]}" -t 2.8 "$W/hseg_b.mp4"

# C — grey-sky flock, 6 s → 16 s of the render (10 s).
ffmpeg -hide_banner -loglevel error -y -ss 6 -t 10 -i "$BIRDS" \
  -loop 1 -t 10 -i "$W/hcap_3.png" -loop 1 -t 10 -i "$W/hcap_4.png" \
  -filter_complex "\
[0:v]${V}[bg];\
[1:v]format=rgba,crop=886:1920,fade=t=in:st=0.4:d=0.45:alpha=1,fade=t=out:st=4.2:d=0.45:alpha=1[c3];\
[2:v]format=rgba,crop=886:1920,fade=t=in:st=5.0:d=0.45:alpha=1,fade=t=out:st=9.2:d=0.5:alpha=1[c4];\
[bg][c3]overlay=0:0[v1];[v1][c4]overlay=0:0[v]" \
  -map "[v]" "${ENC[@]}" -t 10 "$W/hseg_c.mp4"

# D — endcard (3 s).
ffmpeg -hide_banner -loglevel error -y -loop 1 -t 3 -i "$W/endcard.png" \
  -filter_complex "[0:v]${V}[v]" -map "[v]" "${ENC[@]}" -t 3 "$W/hseg_d.mp4"

# Crossfade A→B→C→D (0.6 s each) and add a silent stereo track.
#   lengths: A 7.0, B 2.8, C 10, D 3  →  offsets 6.4, 8.6, 18.0  →  total 21.0 s
ffmpeg -hide_banner -loglevel error -y \
  -i "$W/hseg_a.mp4" -i "$W/hseg_b.mp4" -i "$W/hseg_c.mp4" -i "$W/hseg_d.mp4" \
  -f lavfi -t 30 -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -filter_complex "\
[0:v][1:v]xfade=transition=fade:duration=0.6:offset=6.4[v1];\
[v1][2:v]xfade=transition=fade:duration=0.6:offset=8.6[v2];\
[v2][3:v]xfade=transition=fade:duration=0.6:offset=18.0[v]" \
  -map "[v]" -map 4:a -shortest \
  -c:v libx264 -crf 18 -pix_fmt yuv420p -r 30 -c:a aac -b:a 128k -movflags +faststart "$OUT"

ffprobe -v error -show_entries format=duration -show_entries stream=codec_type,codec_name,width,height,r_frame_rate \
  -of default=noprint_wrappers=1 "$OUT"
echo "Wrote $OUT"; ls -la "$OUT"
