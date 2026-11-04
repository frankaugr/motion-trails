#!/usr/bin/env python3
"""Step 4 — generate the promotional App Store screenshots for iPhone (all four accepted sizes).

Six screens, alternating pure trail imagery with the app's real editor chrome:

  01_hero         sunset geese trail — "Turn motion into trails"
  02_beforeafter  sunset raw frame vs. finished trail, split card
  03_tune         sunset mid-build with the Trails panel (Density slider + Generate bar)
  04_detect       dense grey-sky flock — speed-keyed detection
  05_effects      Effects panel (Fade / Colour / Handheld + Depth parallax) over a trail still
  06_steps        Record · Tune · Share, feature pills, "Every effect included"

Brand tokens come from Theme.swift (canvas #0e0e11, surface #1a1b20, accent #5cccaa). The editor
chrome mirrors RenderView — pill chips, a raised panel with "Density" + value in accent, the
"✦ Generate · N s clip" bar — so the screenshots show the UI the reviewer will actually meet.
Authored in design-px against a 1290-wide canvas and emitted in vw units, so one HTML renders at
every ~19.5:9 iPhone size App Store Connect accepts.

Stills are cut from the engine renders in marketing/build/ (run 02_render_trails.sh and
02b_render_extras.sh first) into marketing/work/stills/. If build/birds_gradient_trail.mp4 exists,
05_effects uses the age-gradient render and shows the Colour controls in the gradient state;
otherwise it falls back to the natural render with Colour = Natural (never shows a state the
picture doesn't match).

Also exports work/preview_editor.html — the 03_tune device card at 1080x1920 — which
06_preview_sunset_birds.sh rasterizes as the "tune it live" beat of the app preview video."""
import os, subprocess, sys, time, tempfile, shutil, signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MK = os.path.join(ROOT, "marketing")
WORK = os.path.join(MK, "work")
STILLS = os.path.join(WORK, "stills")
SS = os.path.join(MK, "screenshots")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

# Every iPhone size App Store Connect accepts, by display slot (all ~19.5:9, so one design fits all).
SIZES = [
    ("iphone-6.9-1320x2868", 1320, 2868),   # 6.9" display (15/16 Pro Max, 16 Plus)
    ("iphone-6.7-1290x2796", 1290, 2796),   # 6.7"/6.9" display
    ("iphone-6.5-1284x2778", 1284, 2778),   # 6.5" slot (also legacy 6.7")
    ("iphone-6.5-1242x2688", 1242, 2688),   # 6.5" display (XS Max / 11 Pro Max)
]
for d in [WORK, STILLS] + [os.path.join(SS, n) for n, _w, _h in SIZES]:
    os.makedirs(d, exist_ok=True)

# ---------------------------------------------------------------------------------------------
# Stills — (output name, source video, timestamp). Cut once; re-cut by deleting the PNG.
# ---------------------------------------------------------------------------------------------
STILL_SPECS = [
    ("sunset_raw.png",   "source/sunset_geese_master.mp4",   0.30),
    ("sunset_6.5.png",   "build/sunset_birds_2x_trail.mp4",  6.50),
    ("sunset_8.5.png",   "build/sunset_birds_2x_trail.mp4",  8.50),
    ("sunset_10.3.png",  "build/sunset_birds_2x_trail.mp4", 10.30),
    ("raw_2.png",        "source/birds_portrait_master.mp4",  2.00),
    ("trail_8.png",      "build/birds_trail.mp4",             8.00),
    ("trail_11.png",     "build/birds_trail.mp4",            11.00),
    ("trail_14.png",     "build/birds_trail.mp4",            14.00),
    ("trail_20.png",     "build/birds_trail.mp4",            20.00),
    ("trail_24.png",     "build/birds_trail.mp4",            24.00),
    # Optional extras (02b_render_extras.sh) — skipped silently when the render isn't there.
    ("gradient_14.png",  "build/birds_gradient_trail.mp4",   14.00),
    ("storks_9.png",     "build/storks_trail.mp4",            9.00),
]

def cut_stills():
    for name, src, t in STILL_SPECS:
        out = os.path.join(STILLS, name)
        srcp = os.path.join(MK, src)
        if os.path.exists(out):
            continue
        if not os.path.exists(srcp):
            print(f"  (skip {name}: {src} not rendered)")
            continue
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{t:.2f}", "-i", srcp,
                        "-frames:v", "1", out], check=True)
        print("  cut", name)

def still(name):
    return os.path.join(STILLS, name)

def have(name):
    return os.path.exists(still(name))

# ---------------------------------------------------------------------------------------------
# Design tokens + base CSS
# ---------------------------------------------------------------------------------------------
DESIGN_W = 1290
def vw(px): return f"{px / DESIGN_W * 100:.4f}vw"
def furl(p): return "file://" + p

ACCENT, CANVAS, SURFACE, SURFACE2, MUTED, ONACC = "#5cccaa", "#0e0e11", "#1a1b20", "#2a2b32", "#9498a3", "#042120"
TEXT2 = "#c8ccd4"

BASE_CSS = f"""
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:100vw;height:100vh;overflow:hidden;background:{CANVAS};color:#fff;
  font-family:-apple-system,"SF Pro Display","SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased}}
.frame{{position:absolute;inset:0;display:flex;flex-direction:column;
  padding:{vw(150)} {vw(76)} {vw(120)}}}
.glow{{position:absolute;left:50%;top:{vw(60)};transform:translateX(-50%);
  width:{vw(1500)};height:{vw(1500)};border-radius:50%;pointer-events:none;
  background:radial-gradient(circle,rgba(92,204,170,.12) 0%,rgba(92,204,170,.03) 40%,transparent 68%)}}
.glow.warm{{background:radial-gradient(circle,rgba(242,170,120,.14) 0%,rgba(242,170,120,.04) 40%,transparent 68%)}}
.eyebrow{{display:flex;align-items:center;gap:{vw(18)};font-size:{vw(25)};font-weight:700;
  letter-spacing:{vw(4)};text-transform:uppercase;color:{ACCENT}}}
.eyebrow .ic{{width:{vw(48)};height:{vw(48)};border-radius:{vw(12)};object-fit:cover;
  box-shadow:0 {vw(6)} {vw(16)} rgba(0,0,0,.5)}}
h1{{font-size:{vw(92)};line-height:1.04;font-weight:700;letter-spacing:{vw(-2)};margin-top:{vw(34)}}}
h1 .a{{color:{ACCENT}}}
.sub{{font-size:{vw(38)};line-height:1.34;font-weight:400;color:{MUTED};margin-top:{vw(28)};
  max-width:{vw(1060)}}}
.card{{position:relative;margin-top:{vw(70)};flex:1;border-radius:{vw(60)};background:#000;
  padding:{vw(12)};box-shadow:0 {vw(40)} {vw(90)} rgba(0,0,0,.6),0 0 0 {vw(1)} rgba(255,255,255,.07),
  0 0 {vw(120)} rgba(92,204,170,.10)}}
.screen{{position:absolute;inset:{vw(12)};border-radius:{vw(50)};overflow:hidden;background:{CANVAS}}}
.screen img.bg{{width:100%;height:100%;object-fit:cover;object-position:center}}
.screen img.bg.up{{height:112%;margin-top:-12%}}
.badge{{position:absolute;top:{vw(28)};right:{vw(28)};font-size:{vw(24)};font-weight:500;color:#e6e8ee;
  background:rgba(14,14,17,.72);padding:{vw(10)} {vw(22)};border-radius:{vw(18)};z-index:3}}
"""

GLOW = '<div class="glow"></div>'
GLOW_WARM = '<div class="glow warm"></div>'

def card(img, inner="", badge=None, up=False):
    b = f'<div class="badge">{badge}</div>' if badge else ""
    return f'<div class="card"><div class="screen"><img class="bg{" up" if up else ""}" src="{furl(img)}">{b}{inner}</div></div>'

def page(body, extra_css=""):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS}{extra_css}</style></head><body>{body}</body></html>"

# ---------------------------------------------------------------------------------------------
# Editor chrome — mirrors RenderView: chip row, raised panel, Generate bar.
# ---------------------------------------------------------------------------------------------
CHIPS = ["Trails", "Motion", "Scene", "Crop", "Effects"]

CHROME_CSS = f"""
.ui{{position:absolute;left:0;right:0;bottom:0;padding:{vw(120)} {vw(26)} {vw(30)};z-index:2;
  background:linear-gradient(to top,rgba(10,11,13,.97) 0%,rgba(10,11,13,.92) 70%,rgba(10,11,13,0) 100%)}}
.chips{{display:flex;gap:{vw(14)};margin-bottom:{vw(22)}}}
.chip{{font-size:{vw(27)};font-weight:500;color:{TEXT2};padding:{vw(16)} {vw(30)};border-radius:{vw(40)};background:{SURFACE}}}
.chip.on{{background:{ACCENT};color:{ONACC};font-weight:600}}
.panel{{background:{SURFACE};border-radius:{vw(26)};padding:{vw(26)} {vw(26)} {vw(22)};
  display:flex;flex-direction:column;gap:{vw(14)}}}
.row{{display:flex;justify-content:space-between;align-items:center;font-size:{vw(28)};font-weight:500;color:#fff}}
.row .v{{color:{ACCENT};font-weight:400}}
.track{{height:{vw(10)};border-radius:{vw(5)};background:{SURFACE2};position:relative;margin:{vw(14)} 0 {vw(6)}}}
.track .fill{{position:absolute;left:0;top:0;bottom:0;border-radius:{vw(5)};background:{ACCENT}}}
.track .knob{{position:absolute;top:50%;transform:translate(-50%,-50%);width:{vw(48)};height:{vw(40)};
  border-radius:{vw(20)};background:#fff;box-shadow:0 {vw(3)} {vw(10)} rgba(0,0,0,.45)}}
.scale{{display:flex;justify-content:space-between;font-size:{vw(21)};color:{MUTED}}}
.cap{{font-size:{vw(21)};color:{MUTED};line-height:1.3}}
.opts{{display:flex;gap:{vw(10)};flex-wrap:wrap}}
.opt{{font-size:{vw(23)};color:{MUTED};padding:{vw(10)} {vw(22)};border-radius:{vw(30)};background:{SURFACE2}}}
.opt.on{{background:{ACCENT};color:{ONACC};font-weight:600}}
.swatches{{display:flex;gap:{vw(40)};font-size:{vw(23)};color:{TEXT2};align-items:center}}
.swatches .sw{{display:inline-block;width:{vw(36)};height:{vw(36)};border-radius:50%;margin-right:{vw(12)};
  vertical-align:middle;box-shadow:0 0 0 {vw(2)} rgba(255,255,255,.18)}}
.toggle{{display:flex;justify-content:space-between;align-items:center;font-size:{vw(25)};color:#fff}}
.toggle .sw{{width:{vw(72)};height:{vw(44)};border-radius:{vw(22)};background:{ACCENT};position:relative}}
.toggle .sw::after{{content:"";position:absolute;top:{vw(4)};right:{vw(4)};width:{vw(36)};height:{vw(36)};
  border-radius:50%;background:#fff}}
.gen{{margin-top:{vw(22)};height:{vw(92)};border-radius:{vw(22)};background:{ACCENT};color:{ONACC};
  display:flex;align-items:center;justify-content:center;font-size:{vw(31)};font-weight:700;gap:{vw(14)}}}
.gen .spark{{font-size:{vw(34)};line-height:1}}
"""

def chips(active):
    return '<div class="chips">' + "".join(
        f'<div class="chip {"on" if c == active else ""}">{c}</div>' for c in CHIPS) + "</div>"

def slider(pct):
    return (f'<div class="track"><div class="fill" style="width:{pct}%"></div>'
            f'<div class="knob" style="left:{pct}%"></div></div>')

def generate_bar(clip_len):
    return f'<div class="gen"><span class="spark">✦</span>Generate · {clip_len} clip</div>'

def trails_chrome(clip_len="10 s"):
    return f"""
    <div class="ui">
      {chips("Trails")}
      <div class="panel">
        <div class="row"><span>Density</span><span class="v">0.12 s</span></div>
        {slider(83)}
        <div class="scale"><span>Sparse</span><span>Dense</span></div>
        <div class="cap">A silhouette is left every 0.12 s of the clip, whatever its length.</div>
      </div>
      {generate_bar(clip_len)}
    </div>"""

def motion_chrome(clip_len="24 s"):
    return f"""
    <div class="ui">
      {chips("Motion")}
      <div class="panel">
        <div class="row"><span>Subject contrast</span><span class="v">Silhouette</span></div>
        <div class="opts"><div class="opt">Any</div><div class="opt on">Silhouette</div>
          <div class="opt">Highlight</div><div class="opt">Colour</div></div>
        <div class="row" style="margin-top:{vw(10)}"><span>Speed threshold</span></div>
        {slider(28)}
        <div class="scale"><span>Only fast</span><span>Include slower</span></div>
        <div class="cap">Lower keeps only the fastest motion (birds) and ignores slow drift like clouds.</div>
      </div>
      {generate_bar(clip_len)}
    </div>"""

def effects_chrome(gradient, clip_len="24 s"):
    colour = ('<div class="opts"><div class="opt">Natural</div><div class="opt on">Age gradient</div></div>'
              f'<div class="swatches"><span><span class="sw" style="background:#ff8c0d"></span>Start</span>'
              f'<span><span class="sw" style="background:#294ceb"></span>End</span></div>'
              if gradient else
              '<div class="opts"><div class="opt on">Natural</div><div class="opt">Age gradient</div></div>')
    fade_v, fade_pct = ("2 s", 20) if gradient else ("Off", 0)
    return f"""
    <div class="ui">
      {chips("Effects")}
      <div class="panel">
        <div class="row"><span>Fade</span><span class="v">{fade_v}</span></div>
        {slider(fade_pct)}
        <div class="scale"><span>Off</span><span>10 s</span></div>
        <div class="row" style="margin-top:{vw(10)}"><span>Color</span></div>
        {colour}
        <div class="row" style="margin-top:{vw(10)}"><span>Handheld camera</span></div>
        <div class="opts"><div class="opt">None</div><div class="opt on">Low</div>
          <div class="opt">Medium</div><div class="opt">High</div></div>
        <div class="toggle" style="margin-top:{vw(6)}"><span>Depth parallax</span><div class="sw"></div></div>
      </div>
      {generate_bar(clip_len)}
    </div>"""

# ---------------------------------------------------------------------------------------------
# Split before/after card
# ---------------------------------------------------------------------------------------------
SPLIT_CSS = f"""
.split{{position:absolute;inset:{vw(12)};border-radius:{vw(50)};overflow:hidden;display:flex;flex-direction:column}}
.split .half{{position:relative;flex:1;overflow:hidden}}
.split .half img{{position:absolute;left:0;width:100%;height:200%;object-fit:cover;object-position:center}}
.split .top img{{top:0}}
.split .bot img{{bottom:0}}
.split .seam{{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);height:{vw(3)};
  background:rgba(92,204,170,.75);z-index:2;box-shadow:0 0 {vw(24)} rgba(92,204,170,.5)}}
.tag{{position:absolute;left:{vw(28)};font-size:{vw(24)};font-weight:700;letter-spacing:{vw(3)};
  text-transform:uppercase;color:#fff;background:rgba(10,11,13,.62);padding:{vw(10)} {vw(20)};
  border-radius:{vw(12)};z-index:3}}
"""

def split_card(raw, trail):
    return f"""
    <div class="card"><div class="split">
      <div class="half top"><img src="{furl(raw)}"><div class="tag" style="top:{vw(26)}">Before</div></div>
      <div class="seam"></div>
      <div class="half bot"><img src="{furl(trail)}"><div class="tag" style="bottom:{vw(26)}">After</div></div>
    </div></div>"""

# ---------------------------------------------------------------------------------------------
# Steps + feature pills + sign-off
# ---------------------------------------------------------------------------------------------
STEPS_CSS = f"""
.steps{{display:flex;flex-direction:column;gap:{vw(26)};margin-top:{vw(64)}}}
.step{{display:flex;align-items:center;gap:{vw(36)};background:{SURFACE};border-radius:{vw(34)};
  padding:{vw(50)} {vw(46)};box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.05)}}
.step .num{{flex:none;width:{vw(96)};height:{vw(96)};border-radius:50%;background:{ACCENT};color:{ONACC};
  display:flex;align-items:center;justify-content:center;font-size:{vw(48)};font-weight:800}}
.step .st{{font-size:{vw(46)};font-weight:700}}
.step .sd{{font-size:{vw(32)};color:{MUTED};margin-top:{vw(6)}}}
.pills{{display:flex;flex-wrap:wrap;gap:{vw(18)};margin-top:{vw(56)};justify-content:center}}
.pill{{font-size:{vw(30)};font-weight:500;color:{TEXT2};padding:{vw(18)} {vw(34)};border-radius:{vw(44)};
  background:{SURFACE};box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.06)}}
.pill b{{color:{ACCENT};font-weight:600}}
.strip{{margin-top:auto;height:{vw(560)};border-radius:{vw(44)};overflow:hidden;position:relative;
  box-shadow:0 {vw(30)} {vw(70)} rgba(0,0,0,.55),0 0 0 {vw(1)} rgba(255,255,255,.07)}}
.strip img{{width:100%;height:100%;object-fit:cover;object-position:center 76%}}
.strip .lbl{{position:absolute;left:{vw(32)};bottom:{vw(26)};font-size:{vw(24)};font-weight:700;letter-spacing:{vw(3)};
  text-transform:uppercase;color:#fff;background:rgba(10,11,13,.62);padding:{vw(10)} {vw(20)};border-radius:{vw(12)}}}
.signoff{{margin-top:{vw(56)};display:flex;flex-direction:column;align-items:center;gap:{vw(22)};text-align:center}}
.signoff img{{width:{vw(170)};height:{vw(170)};border-radius:{vw(38)};object-fit:cover;
  box-shadow:0 {vw(24)} {vw(56)} rgba(0,0,0,.55)}}
.signoff .big{{font-size:{vw(44)};font-weight:700;margin-top:{vw(8)}}}
.signoff .big .a{{color:{ACCENT}}}
.signoff .small{{font-size:{vw(29)};color:{MUTED}}}
"""

def steps_block():
    steps = [("Record", "Prop your phone and capture a few seconds."),
             ("Tune", "Set density, speed and effects on a live preview."),
             ("Share", "Export a loop-ready video to Photos.")]
    rows = "".join(f"""
      <div class="step"><div class="num">{i+1}</div>
        <div class="txt"><div class="st">{t}</div><div class="sd">{d}</div></div></div>"""
      for i, (t, d) in enumerate(steps))
    pills = ["Fade", "Colour gradient", "Handheld sway", "Depth parallax", "Frozen or live scene",
             "Ignore regions", "Crop presets", "iPhone &amp; iPad"]
    pillhtml = "".join(f'<div class="pill">{p}</div>' for p in pills)
    signoff = f"""<div class="signoff"><img src="{furl(ICON)}">
      <div class="big"><span class="a">Every effect</span> included</div>
      <div class="small">No in-app purchases · No account · Everything stays on your device</div></div>"""
    strip = f'<div class="strip"><img src="{furl(still("sunset_10.3.png"))}"><div class="lbl">Rendered on device</div></div>'
    return f'<div class="steps">{rows}</div><div class="pills">{pillhtml}</div>{strip}{signoff}'

# ---------------------------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------------------------
def build():
    pages = {}
    gradient = have("gradient_14.png")

    # 01 hero — sunset geese
    body = GLOW_WARM + f"""<div class="frame">
      <div class="eyebrow"><img class="ic" src="{furl(ICON)}">Motion Trails</div>
      <h1>Turn motion<br>into <span class="a">trails</span></h1>
      <div class="sub">Point at something fast. Every pass paints a daylight long-exposure trail over a perfectly still scene.</div>
      {card(still('sunset_8.5.png'))}
    </div>"""
    pages["01_hero"] = page(body)

    # 02 before / after — sunset
    body = GLOW_WARM + f"""<div class="frame">
      <div class="eyebrow">From clip to loop</div>
      <h1>One locked-off<br>shot, <span class="a">transformed</span></h1>
      <div class="sub">A few seconds of ordinary video in. A clean, loop-ready long exposure out.</div>
      {split_card(still('sunset_raw.png'), still('sunset_10.3.png'))}
    </div>"""
    pages["02_beforeafter"] = page(body, SPLIT_CSS)

    # 03 tune — real Trails panel over the sunset mid-build
    body = GLOW + f"""<div class="frame">
      <div class="eyebrow">Live preview</div>
      <h1>Tune it in<br><span class="a">real time</span></h1>
      <div class="sub">Density, speed threshold, fade and colour — every change shows on the preview before you render.</div>
      {card(still('sunset_10.3.png'), trails_chrome('10 s'), badge='Preview', up=True)}
    </div>"""
    pages["03_tune"] = page(body, CHROME_CSS)

    # 04 detect — dense grey-sky flock, Motion panel
    body = GLOW + f"""<div class="frame">
      <div class="eyebrow">Keyed on speed</div>
      <h1>Fast motion<br>becomes <span class="a">art</span></h1>
      <div class="sub">Birds, cyclists, traffic and waves leave trails. Drifting clouds, swaying trees and changing light don't.</div>
      {card(still('trail_20.png'), motion_chrome('24 s'), badge='Preview')}
    </div>"""
    pages["04_detect"] = page(body, CHROME_CSS)

    # 05 effects
    img = still('gradient_14.png') if gradient else still('trail_14.png')
    body = GLOW + f"""<div class="frame">
      <div class="eyebrow">Effects</div>
      <h1>Fade, colour<br>and <span class="a">sway</span></h1>
      <div class="sub">Let marks melt away, sweep older trails through a colour gradient, or add handheld sway with depth parallax.</div>
      {card(img, effects_chrome(gradient, '24 s'), badge='Preview')}
    </div>"""
    pages["05_effects"] = page(body, CHROME_CSS)

    # 06 steps
    body = GLOW + f"""<div class="frame">
      <div>
        <div class="eyebrow">Three steps</div>
        <h1>Lock the camera.<br>We do the <span class="a">rest</span>.</h1>
      </div>
      {steps_block()}
    </div>"""
    pages["06_steps"] = page(body, STEPS_CSS)

    return pages

# The 03_tune device card alone, at 1080x1920 px, for the app-preview video's editor beat.
def preview_editor_page():
    css = f"""
    *{{margin:0;padding:0;box-sizing:border-box}}
    html,body{{width:1080px;height:1920px;overflow:hidden;background:{CANVAS};color:#fff;
      font-family:-apple-system,"SF Pro Display","SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;
      -webkit-font-smoothing:antialiased}}
    .shot{{position:absolute;inset:0}}
    .shot img.bg{{width:100%;height:100%;object-fit:cover}}
    .badge{{position:absolute;top:120px;right:36px;font-size:26px;font-weight:500;color:#e6e8ee;
      background:rgba(14,14,17,.72);padding:12px 24px;border-radius:20px;z-index:3}}
    .ui{{position:absolute;left:0;right:0;bottom:0;padding:140px 36px 70px;z-index:2;
      background:linear-gradient(to top,rgba(10,11,13,.97) 0%,rgba(10,11,13,.92) 70%,rgba(10,11,13,0) 100%)}}
    .chips{{display:flex;gap:16px;margin-bottom:26px}}
    .chip{{font-size:30px;font-weight:500;color:{TEXT2};padding:18px 34px;border-radius:44px;background:{SURFACE}}}
    .chip.on{{background:{ACCENT};color:{ONACC};font-weight:600}}
    .panel{{background:{SURFACE};border-radius:28px;padding:30px 30px 26px;display:flex;flex-direction:column;gap:16px}}
    .row{{display:flex;justify-content:space-between;align-items:center;font-size:31px;font-weight:500}}
    .row .v{{color:{ACCENT};font-weight:400}}
    .track{{height:12px;border-radius:6px;background:{SURFACE2};position:relative;margin:16px 0 6px}}
    .track .fill{{position:absolute;left:0;top:0;bottom:0;border-radius:6px;background:{ACCENT};width:83%}}
    .track .knob{{position:absolute;left:83%;top:50%;transform:translate(-50%,-50%);width:54px;height:44px;
      border-radius:22px;background:#fff;box-shadow:0 3px 10px rgba(0,0,0,.45)}}
    .scale{{display:flex;justify-content:space-between;font-size:24px;color:{MUTED}}}
    .cap{{font-size:24px;color:{MUTED};line-height:1.3}}
    .gen{{margin-top:26px;height:104px;border-radius:24px;background:{ACCENT};color:{ONACC};
      display:flex;align-items:center;justify-content:center;font-size:35px;font-weight:700;gap:16px}}
    .gen .spark{{font-size:38px;line-height:1}}
    """
    body = f"""
    <div class="shot"><img class="bg" src="{furl(still('sunset_6.5.png'))}">
      <div class="badge">Preview</div>
      <div class="ui">
        <div class="chips">{"".join(f'<div class="chip {"on" if c=="Trails" else ""}">{c}</div>' for c in CHIPS)}</div>
        <div class="panel">
          <div class="row"><span>Density</span><span class="v">0.12 s</span></div>
          <div class="track"><div class="fill"></div><div class="knob"></div></div>
          <div class="scale"><span>Sparse</span><span>Dense</span></div>
          <div class="cap">A silhouette is left every 0.12 s of the clip, whatever its length.</div>
        </div>
        <div class="gen"><span class="spark">✦</span>Generate · 10 s clip</div>
      </div>
    </div>"""
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}</body></html>"

# ---------------------------------------------------------------------------------------------
def shoot(html_path, out_path, w, h, profile):
    if os.path.exists(out_path): os.remove(out_path)
    p = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--no-first-run",
        "--no-default-browser-check", f"--user-data-dir={profile}", "--allow-file-access-from-files",
        "--force-device-scale-factor=1", f"--window-size={w},{h}", "--hide-scrollbars",
        f"--screenshot={out_path}", furl(html_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            time.sleep(0.5); break
        time.sleep(0.4)
    p.send_signal(signal.SIGKILL); p.wait()

def main():
    print("stills:")
    cut_stills()
    for req in ("sunset_raw.png", "sunset_6.5.png", "sunset_8.5.png", "sunset_10.3.png", "trail_14.png", "trail_20.png"):
        if not have(req):
            sys.exit(f"missing still {req} — run marketing/scripts/02_render_trails.sh and 02b_render_extras.sh first")

    pages = build()
    with open(os.path.join(WORK, "preview_editor.html"), "w") as f:
        f.write(preview_editor_page())

    # Clear the old 5-screen numbering so stale files never get uploaded alongside the new set.
    for folder, _w, _h in SIZES:
        for f in os.listdir(os.path.join(SS, folder)):
            if f.endswith(".png") and f[:-4] not in pages:
                os.remove(os.path.join(SS, folder, f))

    profile = tempfile.mkdtemp()
    try:
        for name, html in pages.items():
            hp = os.path.join(WORK, f"ss_{name}.html")
            with open(hp, "w") as f: f.write(html)
            for folder, w, h in SIZES:
                shoot(hp, os.path.join(SS, folder, f"{name}.png"), w, h, profile)
            print("rendered", name)
    finally:
        subprocess.run(["pkill", "-9", "-f", profile], stderr=subprocess.DEVNULL)
        shutil.rmtree(profile, ignore_errors=True)

    from PIL import Image
    for folder, w, h in SIZES:
        d = os.path.join(SS, folder)
        files = sorted(f for f in os.listdir(d) if f.endswith(".png"))
        sizes = {Image.open(os.path.join(d, f)).size for f in files}
        ok = sizes == {(w, h)}
        print(folder, "->", len(files), "files", sizes, "OK" if ok else "SIZE MISMATCH")

if __name__ == "__main__":
    main()
