#!/usr/bin/env python3
"""Step 4b — promotional App Store screenshots for iPad (12.9" 2048x2732 + 13" 2064x2752).

Same six screens as 04_screenshots.py, re-laid for the 4:3 canvas: a blurred, dimmed full-bleed
trail backdrop, centred copy, and a sharp portrait device card. One difference — 03_tune uses a
REAL iPad capture (marketing/source/captures/ipad_editor.png, a frame from a physical-device
screen recording with the status bar cropped) in an iPad-aspect card, so the iPad set shows the
app's actual iPad layout (Guideline 2.3.3 hedge). Authored in design-px against a 2048-wide canvas,
emitted in vw so it scales between the two near-identical iPad aspect ratios."""
import os, subprocess, sys, time, tempfile, shutil, signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MK = os.path.join(ROOT, "marketing")
WORK = os.path.join(MK, "work")
STILLS = os.path.join(WORK, "stills")
CAPTURES = os.path.join(MK, "source", "captures")
OUT129 = os.path.join(MK, "screenshots", "ipad-12.9")
OUT13 = os.path.join(MK, "screenshots", "ipad-13")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
for d in (OUT129, OUT13, WORK):
    os.makedirs(d, exist_ok=True)

DESIGN_W = 2048
def vw(px): return f"{px / DESIGN_W * 100:.4f}vw"
# Chrome inside the device card: the card is ~930 design-px wide here vs 1138 on iPhone, so the
# iPhone chrome metrics are scaled by 0.82 to keep the same proportions on the card.
def cw(px): return vw(px * 0.82)
def furl(p): return "file://" + p
def still(name): return os.path.join(STILLS, name)
def have(name): return os.path.exists(still(name))

ACCENT, CANVAS, SURFACE, SURFACE2, MUTED, ONACC = "#5cccaa", "#0e0e11", "#1a1b20", "#2a2b32", "#9498a3", "#042120"
TEXT2 = "#c8ccd4"

BASE_CSS = f"""
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:100vw;height:100vh;overflow:hidden;background:{CANVAS};color:#fff;
  font-family:-apple-system,"SF Pro Display","SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased}}
.bgimg{{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;
  filter:blur({vw(60)}) brightness(.34) saturate(.9);transform:scale(1.1)}}
.veil{{position:absolute;inset:0;background:
  radial-gradient(120% 80% at 50% 0%,rgba(14,14,17,.55),rgba(14,14,17,.86))}}
.frame{{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;
  text-align:center;padding:{vw(170)} {vw(170)} {vw(150)}}}
.eyebrow{{display:flex;align-items:center;gap:{vw(20)};font-size:{vw(30)};font-weight:700;
  letter-spacing:{vw(5)};text-transform:uppercase;color:{ACCENT}}}
.eyebrow .ic{{width:{vw(58)};height:{vw(58)};border-radius:{vw(14)};object-fit:cover}}
h1{{font-size:{vw(120)};line-height:1.04;font-weight:700;letter-spacing:{vw(-2.5)};margin-top:{vw(34)}}}
h1 .a{{color:{ACCENT}}}
.sub{{font-size:{vw(46)};line-height:1.34;font-weight:400;color:#c2c6cf;margin-top:{vw(30)};max-width:{vw(1420)}}}
.cardwrap{{flex:1;width:100%;display:flex;align-items:center;justify-content:center;margin-top:{vw(80)};min-height:0}}
.card{{position:relative;height:100%;aspect-ratio:1080/1920;border-radius:{vw(72)};background:#000;
  padding:{vw(14)};box-shadow:0 {vw(50)} {vw(120)} rgba(0,0,0,.7),0 0 0 {vw(1.5)} rgba(255,255,255,.08),
  0 0 {vw(160)} rgba(92,204,170,.12)}}
.card.pad{{aspect-ratio:1640/2300}}
.screen{{position:absolute;inset:{vw(14)};border-radius:{vw(60)};overflow:hidden;background:{CANVAS}}}
.screen img.bg{{width:100%;height:100%;object-fit:cover;object-position:center}}
.screen img.bg.up{{height:112%;margin-top:-12%}}
.badge{{position:absolute;top:{cw(28)};right:{cw(28)};font-size:{cw(24)};font-weight:500;color:#e6e8ee;
  background:rgba(14,14,17,.72);padding:{cw(10)} {cw(22)};border-radius:{cw(18)};z-index:3}}
"""

CHIPS = ["Trails", "Motion", "Scene", "Crop", "Effects"]
CHROME_CSS = f"""
.ui{{position:absolute;left:0;right:0;bottom:0;padding:{cw(120)} {cw(26)} {cw(30)};z-index:2;
  background:linear-gradient(to top,rgba(10,11,13,.97) 0%,rgba(10,11,13,.92) 70%,rgba(10,11,13,0) 100%)}}
.chips{{display:flex;gap:{cw(14)};margin-bottom:{cw(22)}}}
.chip{{font-size:{cw(27)};font-weight:500;color:{TEXT2};padding:{cw(16)} {cw(30)};border-radius:{cw(40)};background:{SURFACE}}}
.chip.on{{background:{ACCENT};color:{ONACC};font-weight:600}}
.panel{{background:{SURFACE};border-radius:{cw(26)};padding:{cw(26)} {cw(26)} {cw(22)};display:flex;flex-direction:column;gap:{cw(14)};text-align:left}}
.row{{display:flex;justify-content:space-between;align-items:center;font-size:{cw(28)};font-weight:500;color:#fff}}
.row .v{{color:{ACCENT};font-weight:400}}
.track{{height:{cw(10)};border-radius:{cw(5)};background:{SURFACE2};position:relative;margin:{cw(14)} 0 {cw(6)}}}
.track .fill{{position:absolute;left:0;top:0;bottom:0;border-radius:{cw(5)};background:{ACCENT}}}
.track .knob{{position:absolute;top:50%;transform:translate(-50%,-50%);width:{cw(48)};height:{cw(40)};
  border-radius:{cw(20)};background:#fff;box-shadow:0 {cw(3)} {cw(10)} rgba(0,0,0,.45)}}
.scale{{display:flex;justify-content:space-between;font-size:{cw(21)};color:{MUTED}}}
.cap{{font-size:{cw(21)};color:{MUTED};line-height:1.3}}
.opts{{display:flex;gap:{cw(10)};flex-wrap:wrap}}
.opt{{font-size:{cw(23)};color:{MUTED};padding:{cw(10)} {cw(22)};border-radius:{cw(30)};background:{SURFACE2}}}
.opt.on{{background:{ACCENT};color:{ONACC};font-weight:600}}
.swatches{{display:flex;gap:{cw(40)};font-size:{cw(23)};color:{TEXT2};align-items:center}}
.swatches .sw{{display:inline-block;width:{cw(36)};height:{cw(36)};border-radius:50%;margin-right:{cw(12)};
  vertical-align:middle;box-shadow:0 0 0 {cw(2)} rgba(255,255,255,.18)}}
.toggle{{display:flex;justify-content:space-between;align-items:center;font-size:{cw(25)};color:#fff}}
.toggle .sw{{width:{cw(72)};height:{cw(44)};border-radius:{cw(22)};background:{ACCENT};position:relative}}
.toggle .sw::after{{content:"";position:absolute;top:{cw(4)};right:{cw(4)};width:{cw(36)};height:{cw(36)};border-radius:50%;background:#fff}}
.gen{{margin-top:{cw(22)};height:{cw(92)};border-radius:{cw(22)};background:{ACCENT};color:{ONACC};
  display:flex;align-items:center;justify-content:center;font-size:{cw(31)};font-weight:700;gap:{cw(14)}}}
.gen .spark{{font-size:{cw(34)};line-height:1}}
"""

def chips(active):
    return '<div class="chips">' + "".join(f'<div class="chip {"on" if c == active else ""}">{c}</div>' for c in CHIPS) + "</div>"
def slider(pct):
    return f'<div class="track"><div class="fill" style="width:{pct}%"></div><div class="knob" style="left:{pct}%"></div></div>'
def generate_bar(clip_len):
    return f'<div class="gen"><span class="spark">✦</span>Generate · {clip_len} clip</div>'

def motion_chrome(clip_len="24 s"):
    return f"""<div class="ui">{chips("Motion")}<div class="panel">
      <div class="row"><span>Subject contrast</span><span class="v">Silhouette</span></div>
      <div class="opts"><div class="opt">Any</div><div class="opt on">Silhouette</div><div class="opt">Highlight</div><div class="opt">Colour</div></div>
      <div class="row" style="margin-top:{cw(10)}"><span>Speed threshold</span></div>{slider(28)}
      <div class="scale"><span>Only fast</span><span>Include slower</span></div>
      <div class="cap">Lower keeps only the fastest motion (birds) and ignores slow drift like clouds.</div>
    </div>{generate_bar(clip_len)}</div>"""

def effects_chrome(gradient, clip_len="24 s"):
    colour = ('<div class="opts"><div class="opt">Natural</div><div class="opt on">Age gradient</div></div>'
              '<div class="swatches"><span><span class="sw" style="background:#ff8c0d"></span>Start</span>'
              '<span><span class="sw" style="background:#294ceb"></span>End</span></div>'
              if gradient else '<div class="opts"><div class="opt on">Natural</div><div class="opt">Age gradient</div></div>')
    fade_v, fade_pct = ("2 s", 20) if gradient else ("Off", 0)
    return f"""<div class="ui">{chips("Effects")}<div class="panel">
      <div class="row"><span>Fade</span><span class="v">{fade_v}</span></div>{slider(fade_pct)}
      <div class="scale"><span>Off</span><span>10 s</span></div>
      <div class="row" style="margin-top:{cw(10)}"><span>Color</span></div>{colour}
      <div class="row" style="margin-top:{cw(10)}"><span>Handheld camera</span></div>
      <div class="opts"><div class="opt">None</div><div class="opt on">Low</div><div class="opt">Medium</div><div class="opt">High</div></div>
      <div class="toggle" style="margin-top:{cw(6)}"><span>Depth parallax</span><div class="sw"></div></div>
    </div>{generate_bar(clip_len)}</div>"""

def shell(hero):
    return f'<img class="bgimg" src="{furl(hero)}"><div class="veil"></div>'

def card(img, inner="", badge=None, up=False, pad=False):
    b = f'<div class="badge">{badge}</div>' if badge else ""
    return (f'<div class="cardwrap"><div class="card{" pad" if pad else ""}"><div class="screen">'
            f'<img class="bg{" up" if up else ""}" src="{furl(img)}">{b}{inner}</div></div></div>')

def page(body, extra=""):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS}{extra}</style></head><body>{body}</body></html>"

SPLIT_CSS = f"""
.split{{position:absolute;inset:{vw(14)};border-radius:{vw(60)};overflow:hidden;display:flex;flex-direction:column}}
.split .half{{flex:1;position:relative;background-size:cover;background-position:center}}
.split .seam{{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);height:{vw(3)};
  background:rgba(92,204,170,.75);z-index:2;box-shadow:0 0 {vw(24)} rgba(92,204,170,.5)}}
.tag{{position:absolute;left:{vw(30)};font-size:{vw(28)};font-weight:700;letter-spacing:{vw(3)};text-transform:uppercase;
  color:#fff;background:rgba(10,11,13,.62);padding:{vw(12)} {vw(22)};border-radius:{vw(14)};z-index:3}}
"""
def split_card(raw, trail):
    return (f'<div class="cardwrap"><div class="card"><div class="split">'
            f'<div class="half" style="background-image:url({furl(raw)})"><div class="tag" style="top:{vw(26)}">Before</div></div>'
            f'<div class="seam"></div>'
            f'<div class="half" style="background-image:url({furl(trail)})"><div class="tag" style="bottom:{vw(26)}">After</div></div>'
            f'</div></div></div>')

STEPS_CSS = f"""
.cols{{display:flex;align-items:stretch;justify-content:center;gap:{vw(40)};width:100%;margin-top:{vw(90)}}}
.scol{{flex:1;max-width:{vw(540)};background:{SURFACE};border-radius:{vw(40)};padding:{vw(60)} {vw(46)};
  box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.05);display:flex;flex-direction:column;align-items:center;text-align:center}}
.scol .num{{width:{vw(118)};height:{vw(118)};border-radius:50%;background:{ACCENT};color:{ONACC};
  display:flex;align-items:center;justify-content:center;font-size:{vw(58)};font-weight:800;margin-bottom:{vw(34)}}}
.scol .st{{font-size:{vw(54)};font-weight:700}}
.scol .sd{{font-size:{vw(34)};color:{MUTED};margin-top:{vw(14)};white-space:pre-line;line-height:1.32}}
.pills{{display:flex;flex-wrap:wrap;gap:{vw(20)};margin-top:{vw(70)};justify-content:center;max-width:{vw(1500)}}}
.pill{{font-size:{vw(32)};font-weight:500;color:{TEXT2};padding:{vw(18)} {vw(36)};border-radius:{vw(44)};background:{SURFACE};
  box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.06)}}
.strip{{margin-top:auto;width:100%;height:{vw(540)};border-radius:{vw(48)};overflow:hidden;position:relative;
  box-shadow:0 {vw(30)} {vw(70)} rgba(0,0,0,.55),0 0 0 {vw(1)} rgba(255,255,255,.07)}}
.strip img{{width:100%;height:100%;object-fit:cover;object-position:center 76%}}
.strip .lbl{{position:absolute;left:{vw(34)};bottom:{vw(28)};font-size:{vw(26)};font-weight:700;letter-spacing:{vw(3)};
  text-transform:uppercase;color:#fff;background:rgba(10,11,13,.62);padding:{vw(12)} {vw(22)};border-radius:{vw(14)}}}
.signoff{{display:flex;flex-direction:column;align-items:center;gap:{vw(22)};margin-top:{vw(60)}}}
.signoff img{{width:{vw(160)};height:{vw(160)};border-radius:{vw(36)};object-fit:cover}}
.signoff .big{{font-size:{vw(50)};font-weight:700}} .signoff .big .a{{color:{ACCENT}}}
.signoff .small{{font-size:{vw(32)};color:{MUTED}}}
"""
def steps_block():
    steps = [("Record", "Prop your iPad or iPhone.\nCapture a few seconds."),
             ("Tune", "Set density, speed and effects\non a live preview."),
             ("Share", "Export a loop-ready\nvideo to Photos.")]
    cols = "".join(f'<div class="scol"><div class="num">{i+1}</div><div class="st">{t}</div><div class="sd">{d}</div></div>'
                   for i, (t, d) in enumerate(steps))
    pills = ["Fade", "Colour gradient", "Handheld sway", "Depth parallax", "Frozen or live scene",
             "Ignore regions", "Crop presets", "iPhone &amp; iPad"]
    pillhtml = "".join(f'<div class="pill">{p}</div>' for p in pills)
    strip = f'<div class="strip"><img src="{furl(still("sunset_10.3.png"))}"><div class="lbl">Rendered on device</div></div>'
    signoff = (f'<div class="signoff"><img src="{furl(ICON)}"><div class="big"><span class="a">Every effect</span> included</div>'
               f'<div class="small">No in-app purchases · No account · Everything stays on your device</div></div>')
    return f'<div class="cols">{cols}</div><div class="pills">{pillhtml}</div>{strip}{signoff}'

def build():
    pages = {}
    gradient = have("gradient_14.png")
    real_editor = os.path.join(CAPTURES, "ipad_editor.png")

    body = shell(still('sunset_8.5.png')) + f"""<div class="frame">
      <div class="eyebrow"><img class="ic" src="{furl(ICON)}">Motion Trails</div>
      <h1>Turn motion into <span class="a">trails</span></h1>
      <div class="sub">Point at something fast. Every pass paints a daylight long-exposure trail over a perfectly still scene.</div>
      {card(still('sunset_8.5.png'))}</div>"""
    pages["01_hero"] = page(body)

    body = shell(still('sunset_10.3.png')) + f"""<div class="frame">
      <div class="eyebrow">From clip to loop</div>
      <h1>One locked-off shot, <span class="a">transformed</span></h1>
      <div class="sub">A few seconds of ordinary video in. A clean, loop-ready long exposure out.</div>
      {split_card(still('sunset_raw.png'), still('sunset_10.3.png'))}</div>"""
    pages["02_beforeafter"] = page(body, SPLIT_CSS)

    if os.path.exists(real_editor):
        tune_card = card(real_editor, pad=True)
        tune_sub = "The real editor on iPad — density, speed threshold, fade and colour, every change on the preview before you render."
    else:
        tune_card = card(still('sunset_10.3.png'), motion_chrome('10 s'), badge='Preview', up=True)
        tune_sub = "Density, speed threshold, fade and colour — every change shows on the preview before you render."
    body = shell(still('trail_11.png')) + f"""<div class="frame">
      <div class="eyebrow">Live preview</div>
      <h1>Tune it in <span class="a">real time</span></h1>
      <div class="sub">{tune_sub}</div>{tune_card}</div>"""
    pages["03_tune"] = page(body, CHROME_CSS)

    body = shell(still('trail_20.png')) + f"""<div class="frame">
      <div class="eyebrow">Keyed on speed</div>
      <h1>Fast motion becomes <span class="a">art</span></h1>
      <div class="sub">Birds, cyclists, traffic and waves leave trails. Drifting clouds, swaying trees and changing light don't.</div>
      {card(still('trail_20.png'), motion_chrome('24 s'), badge='Preview')}</div>"""
    pages["04_detect"] = page(body, CHROME_CSS)

    img = still('gradient_14.png') if gradient else still('trail_14.png')
    body = shell(img) + f"""<div class="frame">
      <div class="eyebrow">Effects</div>
      <h1>Fade, colour and <span class="a">sway</span></h1>
      <div class="sub">Let marks melt away, sweep older trails through a colour gradient, or add handheld sway with depth parallax.</div>
      {card(img, effects_chrome(gradient, '24 s'), badge='Preview')}</div>"""
    pages["05_effects"] = page(body, CHROME_CSS)

    body = shell(still('trail_24.png')) + f"""<div class="frame">
      <div class="eyebrow">Three steps</div>
      <h1>Lock the camera. We do the <span class="a">rest</span>.</h1>
      {steps_block()}</div>"""
    pages["06_steps"] = page(body, STEPS_CSS)
    return pages

def shoot(html_path, out_path, w, h, profile):
    if os.path.exists(out_path): os.remove(out_path)
    p = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
        f"--user-data-dir={profile}", "--allow-file-access-from-files", "--force-device-scale-factor=1",
        f"--window-size={w},{h}", "--hide-scrollbars", f"--screenshot={out_path}", furl(html_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            time.sleep(0.5); break
        time.sleep(0.4)
    p.send_signal(signal.SIGKILL); p.wait()

def main():
    for req in ("sunset_raw.png", "sunset_8.5.png", "sunset_10.3.png", "trail_11.png", "trail_14.png", "trail_20.png", "trail_24.png"):
        if not have(req):
            sys.exit(f"missing still {req} — run 04_screenshots.py first (it cuts the stills)")
    pages = build()
    for d in (OUT129, OUT13):
        for f in os.listdir(d):
            if f.endswith(".png") and f[:-4] not in pages:
                os.remove(os.path.join(d, f))
    profile = tempfile.mkdtemp()
    try:
        for name, html in pages.items():
            hp = os.path.join(WORK, f"ipad_{name}.html")
            with open(hp, "w") as f: f.write(html)
            shoot(hp, os.path.join(OUT129, f"{name}.png"), 2048, 2732, profile)
            shoot(hp, os.path.join(OUT13, f"{name}.png"), 2064, 2752, profile)
            print("rendered", name)
    finally:
        subprocess.run(["pkill", "-9", "-f", profile], stderr=subprocess.DEVNULL)
        shutil.rmtree(profile, ignore_errors=True)
    from PIL import Image
    for d, (w, h) in ((OUT129, (2048, 2732)), (OUT13, (2064, 2752))):
        files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
        sizes = {Image.open(os.path.join(d, f)).size for f in files}
        print(d.split("/")[-1], "->", len(files), "files", sizes, "OK" if sizes == {(w, h)} else "SIZE MISMATCH")

if __name__ == "__main__":
    main()
