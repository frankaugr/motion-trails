#!/bin/bash
# Step 3a — rasterize the endcard (opaque) and caption overlays (transparent) with headless Chrome.
# headless=new doesn't reliably self-terminate after --screenshot, so we launch it, poll for the PNG,
# then kill it. Everything is scoped to a throwaway --user-data-dir so the user's real Chrome is safe.
set -uo pipefail
cd "$(dirname "$0")/../.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
S=marketing/scripts
W=marketing/work
PROFILE="$(mktemp -d)"
trap 'pkill -9 -f "$PROFILE" 2>/dev/null; rm -rf "$PROFILE"' EXIT

cp Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png "$W/icon.png"

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

sed "s#REPLACE_ICON#file://$(pwd)/$W/icon.png#" "$S/endcard.html" > "$W/endcard.filled.html"
shoot "$W/endcard.filled.html" "$W/endcard.png" 1080 1920

sed "s#REPLACE_TEXT#An ordinary, locked-off clip#" "$S/caption.html" > "$W/cap_intro.html"
sed "s#REPLACE_TEXT#Every pass becomes a trail#" "$S/caption.html" > "$W/cap_build.html"
shoot "$W/cap_intro.html" "$W/cap_intro.png" 1080 1920 "--default-background-color=00000000"
shoot "$W/cap_build.html" "$W/cap_build.png" 1080 1920 "--default-background-color=00000000"

python3 - <<'PY'
from PIL import Image
for f in ["endcard","cap_intro","cap_build"]:
    im=Image.open(f"marketing/work/{f}.png")
    alpha = im.mode=="RGBA" and im.getextrema()[3][0] < 255
    print(f, im.size, im.mode, "has-transparency" if alpha else "opaque")
PY
