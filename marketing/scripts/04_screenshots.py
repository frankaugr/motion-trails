#!/usr/bin/env python3
"""Step 4 — generate promotional App Store screenshots (iPhone 6.7" + 6.9").

Brand-token styled (Theme.swift: canvas #0e0e11, surface #1a1b20, accent #5cccaa), with real trail
stills from the engine render as the hero imagery. Authored in design-px against a 1290-wide canvas
and emitted in vw units so the same HTML renders correctly at both 1290x2796 and 1320x2868 (the two
iPhone aspect ratios are effectively identical, 2.168 vs 2.173)."""
import os, subprocess, sys, time, tempfile, shutil, signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WORK = os.path.join(ROOT, "marketing", "work")
STILLS = os.path.join(WORK, "stills")
SS = os.path.join(ROOT, "marketing", "screenshots")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
# Every iPhone size App Store Connect accepts, by display slot (all ~19.5:9, so one design fits all).
SIZES = [
    ("iphone-6.9-1320x2868", 1320, 2868),   # 6.9" display (15/16 Pro Max, 16 Plus)
    ("iphone-6.7-1290x2796", 1290, 2796),   # 6.7"/6.9" display
    ("iphone-6.5-1284x2778", 1284, 2778),   # 6.5" slot (also legacy 6.7")
    ("iphone-6.5-1242x2688", 1242, 2688),   # 6.5" display (XS Max / 11 Pro Max)
]
os.makedirs(WORK, exist_ok=True)
for name, _w, _h in SIZES:
    os.makedirs(os.path.join(SS, name), exist_ok=True)

DESIGN_W = 1290
def vw(px): return f"{px / DESIGN_W * 100:.4f}vw"
def furl(p): return "file://" + p

ACCENT, CANVAS, SURFACE, MUTED, ONACC = "#5cccaa", "#0e0e11", "#1a1b20", "#9498a3", "#042120"

BASE_CSS = f"""
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:100vw;height:100vh;overflow:hidden;background:{CANVAS};color:#fff;
  font-family:-apple-system,"SF Pro Display","Helvetica Neue",Helvetica,Arial,sans-serif;
  -webkit-font-smoothing:antialiased}}
.frame{{position:absolute;inset:0;display:flex;flex-direction:column;
  padding:{vw(150)} {vw(76)} {vw(120)}}}
.glow{{position:absolute;left:50%;top:{vw(60)};transform:translateX(-50%);
  width:{vw(1500)};height:{vw(1500)};border-radius:50%;pointer-events:none;
  background:radial-gradient(circle,rgba(92,204,170,.12) 0%,rgba(92,204,170,.03) 40%,transparent 68%)}}
.eyebrow{{display:flex;align-items:center;gap:{vw(18)};font-size:{vw(25)};font-weight:700;
  letter-spacing:{vw(4)};text-transform:uppercase;color:{ACCENT}}}
.eyebrow .ic{{width:{vw(48)};height:{vw(48)};border-radius:{vw(12)};object-fit:cover;
  box-shadow:0 {vw(6)} {vw(16)} rgba(0,0,0,.5)}}
h1{{font-size:{vw(92)};line-height:1.04;font-weight:700;letter-spacing:{vw(-2)};margin-top:{vw(34)}}}
h1 .a{{color:{ACCENT}}}
.sub{{font-size:{vw(38)};line-height:1.34;font-weight:400;color:{MUTED};margin-top:{vw(28)};
  max-width:{vw(1020)}}}
.card{{position:relative;margin-top:{vw(70)};flex:1;border-radius:{vw(60)};background:#000;
  padding:{vw(12)};box-shadow:0 {vw(40)} {vw(90)} rgba(0,0,0,.6),0 0 0 {vw(1)} rgba(255,255,255,.07),
  0 0 {vw(120)} rgba(92,204,170,.10)}}
.screen{{position:absolute;inset:{vw(12)};border-radius:{vw(50)};overflow:hidden}}
.screen img.bg{{width:100%;height:100%;object-fit:cover;object-position:center}}
"""

PHONE_FRAME = f"""
<div class="glow"></div>
"""

def card(img, inner=""):
    return f'<div class="card"><div class="screen"><img class="bg" src="{furl(img)}">{inner}</div></div>'

def page(body, extra_css=""):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS}{extra_css}</style></head><body>{body}</body></html>"

# ---- Editor chrome recreation for the "tune" screenshot ----
def editor_chrome():
    chips = ["Trails", "Motion", "Scene", "Crop", "Effects"]
    chiphtml = "".join(
        f'<div class="chip {"on" if c=="Motion" else ""}">{c}</div>' for c in chips)
    css = f"""
    .ui{{position:absolute;left:0;right:0;bottom:0;padding:{vw(34)} {vw(34)} {vw(40)};
      background:linear-gradient(to top,rgba(10,11,13,.96) 0%,rgba(10,11,13,.82) 55%,rgba(10,11,13,0) 100%)}}
    .chips{{display:flex;gap:{vw(16)};margin-bottom:{vw(30)}}}
    .chip{{flex:1;text-align:center;font-size:{vw(27)};font-weight:600;color:#c8ccd4;
      padding:{vw(20)} 0;border-radius:{vw(16)};background:{SURFACE}}}
    .chip.on{{background:{ACCENT};color:{ONACC}}}
    .row{{display:flex;justify-content:space-between;font-size:{vw(28)};color:#c8ccd4;margin-bottom:{vw(18)}}}
    .row .v{{color:{ACCENT};font-weight:600}}
    .track{{height:{vw(16)};border-radius:{vw(8)};background:#2a2b32;position:relative;margin-bottom:{vw(36)}}}
    .track .fill{{position:absolute;left:0;top:0;bottom:0;width:62%;border-radius:{vw(8)};background:{ACCENT}}}
    .track .knob{{position:absolute;left:62%;top:50%;transform:translate(-50%,-50%);
      width:{vw(50)};height:{vw(50)};border-radius:50%;background:#fff;box-shadow:0 {vw(4)} {vw(12)} rgba(0,0,0,.5)}}
    .gen{{height:{vw(96)};border-radius:{vw(22)};background:{ACCENT};color:{ONACC};
      display:flex;align-items:center;justify-content:center;font-size:{vw(34)};font-weight:700;gap:{vw(16)}}}
    """
    html = f"""
    <div class="ui">
      <div class="chips">{chiphtml}</div>
      <div class="row"><span>Motion sensitivity</span><span class="v">Birds</span></div>
      <div class="track"><div class="fill"></div><div class="knob"></div></div>
      <div class="gen">Generate trail</div>
    </div>"""
    return html, css

# ---- before/after split for screenshot 4 ----
def split_card(raw, trail):
    css = f"""
    .split{{position:absolute;inset:{vw(12)};border-radius:{vw(50)};overflow:hidden;display:flex;flex-direction:column}}
    .split .half{{position:relative;flex:1;overflow:hidden}}
    .split .half img{{position:absolute;width:100%;height:200%;object-fit:cover;object-position:center}}
    .split .top img{{top:0}}
    .split .bot img{{bottom:0}}
    .split .seam{{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);height:{vw(2)};
      background:rgba(92,204,170,.6);z-index:2}}
    .tag{{position:absolute;left:{vw(28)};font-size:{vw(24)};font-weight:700;letter-spacing:{vw(3)};
      text-transform:uppercase;color:#fff;background:rgba(10,11,13,.6);padding:{vw(10)} {vw(20)};
      border-radius:{vw(12)};z-index:3}}
    """
    html = f"""
    <div class="card"><div class="split">
      <div class="half top"><img src="{furl(raw)}"><div class="tag" style="top:{vw(24)}">Before</div></div>
      <div class="seam"></div>
      <div class="half bot"><img src="{furl(trail)}"><div class="tag" style="bottom:{vw(24)}">After</div></div>
    </div></div>"""
    return html, css

# ---- three-steps screenshot ----
def steps_card():
    steps = [("Record","Prop your phone. Capture a few seconds."),
             ("Tune","Set density and sensitivity on a live preview."),
             ("Share","Export a loop-ready video to Photos.")]
    rows = "".join(f"""
      <div class="step"><div class="num">{i+1}</div>
        <div class="txt"><div class="st">{t}</div><div class="sd">{d}</div></div></div>"""
      for i,(t,d) in enumerate(steps))
    css = f"""
    .steps{{display:flex;flex-direction:column;gap:{vw(36)}}}
    .step{{display:flex;align-items:center;gap:{vw(36)};background:{SURFACE};border-radius:{vw(34)};
      padding:{vw(52)} {vw(46)};box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.05)}}
    .step .num{{flex:none;width:{vw(100)};height:{vw(100)};border-radius:50%;background:{ACCENT};color:{ONACC};
      display:flex;align-items:center;justify-content:center;font-size:{vw(50)};font-weight:800}}
    .step .st{{font-size:{vw(50)};font-weight:700}}
    .step .sd{{font-size:{vw(34)};color:{MUTED};margin-top:{vw(8)}}}
    .signoff{{display:flex;flex-direction:column;align-items:center;gap:{vw(26)}}}
    .signoff img{{width:{vw(168)};height:{vw(168)};border-radius:{vw(38)};object-fit:cover;
      box-shadow:0 {vw(24)} {vw(56)} rgba(0,0,0,.55)}}
    .signoff .free{{font-size:{vw(42)};font-weight:700}}
    .signoff .free .a{{color:{ACCENT}}}
    .signoff .freesub{{font-size:{vw(31)};color:{MUTED}}}
    """
    html = f'<div class="steps">{rows}</div>'
    footer = f"""<div class="signoff"><img src="{furl(ICON)}">
      <div class="free">Free — <span class="a">every effect</span>, no watermark</div>
      <div class="freesub">Turn motion into trails</div></div>"""
    return html, footer, css

# ---- screenshot definitions ----
def build():
    pages = {}

    # 01 hero
    body = PHONE_FRAME + f"""<div class="frame">
      <div class="eyebrow"><img class="ic" src="{furl(ICON)}">Motion Trails</div>
      <h1>Turn motion<br>into <span class="a">trails</span></h1>
      <div class="sub">Point at something fast. Every pass paints a daylight long-exposure trail over a perfectly still scene.</div>
      {card(os.path.join(STILLS,'trail_14.png'))}
    </div>"""
    pages["01_hero"] = page(body)

    # 02 fast motion
    body = PHONE_FRAME + f"""<div class="frame">
      <div class="eyebrow">Automatic detection</div>
      <h1>Fast motion<br>becomes <span class="a">art</span></h1>
      <div class="sub">Birds, cyclists, traffic — fast subjects leave trails. Slow drift like clouds is quietly ignored.</div>
      {card(os.path.join(STILLS,'trail_8.png'))}
    </div>"""
    pages["02_detect"] = page(body)

    # 03 tune (editor chrome)
    ui_html, ui_css = editor_chrome()
    body = PHONE_FRAME + f"""<div class="frame">
      <div class="eyebrow">Live preview</div>
      <h1>Tune it in<br><span class="a">real time</span></h1>
      <div class="sub">Density, motion sensitivity, fade and colour — dial it in on a live preview, then export.</div>
      {card(os.path.join(STILLS,'trail_11.png'), ui_html)}
    </div>"""
    pages["03_tune"] = page(body, ui_css)

    # 04 before/after
    split_html, split_css = split_card(os.path.join(STILLS,'raw_2.png'), os.path.join(STILLS,'trail_20.png'))
    body = PHONE_FRAME + f"""<div class="frame">
      <div class="eyebrow">From clip to loop</div>
      <h1>One locked-off<br>shot, <span class="a">transformed</span></h1>
      <div class="sub">Keep the scene frozen or live underneath. Export a clean, loop-ready video.</div>
      {split_html}
    </div>"""
    pages["04_beforeafter"] = page(body, split_css)

    # 05 three steps
    steps_html, steps_footer, steps_css = steps_card()
    body = PHONE_FRAME + f"""<div class="frame" style="justify-content:space-between">
      <div>
        <div class="eyebrow">Three steps</div>
        <h1>Lock the camera.<br>We do the <span class="a">rest</span>.</h1>
      </div>
      {steps_html}
      {steps_footer}
    </div>"""
    pages["05_steps"] = page(body, steps_css)

    return pages

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
    pages = build()
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
    for folder, _w, _h in SIZES:
        d = os.path.join(SS, folder)
        sizes = {Image.open(os.path.join(d, f)).size for f in os.listdir(d) if f.endswith(".png")}
        print(folder, "->", sizes)

if __name__ == "__main__":
    main()
