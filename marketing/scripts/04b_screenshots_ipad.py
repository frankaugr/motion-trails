#!/usr/bin/env python3
"""Step 4b — promotional App Store screenshots for iPad (12.9" 2048x2732 + 13" 2064x2752).

iPad is 4:3 (~0.75), nothing like iPhone's 0.46, so this is a dedicated layout: a blurred, dimmed
full-bleed trail backdrop fills the wide canvas, a sharp centered portrait device-card carries the
hero imagery, and the three-steps screen becomes a 3-column row. Authored in design-px against a
2048-wide canvas and emitted in vw so it scales between the two near-identical iPad aspect ratios."""
import os, subprocess, time, tempfile, shutil, signal

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WORK = os.path.join(ROOT, "marketing", "work")
STILLS = os.path.join(WORK, "stills")
OUT129 = os.path.join(ROOT, "marketing", "screenshots", "ipad-12.9")
OUT13 = os.path.join(ROOT, "marketing", "screenshots", "ipad-13")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ICON = os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
for d in (OUT129, OUT13, WORK):
    os.makedirs(d, exist_ok=True)

DESIGN_W = 2048
def vw(px): return f"{px / DESIGN_W * 100:.4f}vw"
def furl(p): return "file://" + p
ACCENT, CANVAS, SURFACE, MUTED, ONACC = "#5cccaa", "#0e0e11", "#1a1b20", "#9498a3", "#042120"

BASE_CSS = f"""
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:100vw;height:100vh;overflow:hidden;background:{CANVAS};color:#fff;
  font-family:-apple-system,"SF Pro Display","Helvetica Neue",Helvetica,Arial,sans-serif;
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
.sub{{font-size:{vw(46)};line-height:1.34;font-weight:400;color:#c2c6cf;margin-top:{vw(30)};max-width:{vw(1380)}}}
.cardwrap{{flex:1;width:100%;display:flex;align-items:center;justify-content:center;margin-top:{vw(80)};min-height:0}}
.card{{position:relative;height:100%;aspect-ratio:1080/1920;border-radius:{vw(72)};background:#000;
  padding:{vw(14)};box-shadow:0 {vw(50)} {vw(120)} rgba(0,0,0,.7),0 0 0 {vw(1.5)} rgba(255,255,255,.08),
  0 0 {vw(160)} rgba(92,204,170,.12)}}
.screen{{position:absolute;inset:{vw(14)};border-radius:{vw(60)};overflow:hidden}}
.screen img.bg{{width:100%;height:100%;object-fit:cover;object-position:center}}
"""

def shell(hero):
    return f'<img class="bgimg" src="{furl(hero)}"><div class="veil"></div>'

def card(img, inner=""):
    return f'<div class="cardwrap"><div class="card"><div class="screen"><img class="bg" src="{furl(img)}">{inner}</div></div></div>'

def page(body, extra=""):
    return f"<!doctype html><html><head><meta charset='utf-8'><style>{BASE_CSS}{extra}</style></head><body>{body}</body></html>"

def editor_chrome():
    chips = ["Trails","Motion","Scene","Crop","Effects"]
    ch = "".join(f'<div class="chip {"on" if c=="Motion" else ""}">{c}</div>' for c in chips)
    css = f"""
    .ui{{position:absolute;left:0;right:0;bottom:0;padding:{vw(40)} {vw(40)} {vw(46)};
      background:linear-gradient(to top,rgba(10,11,13,.96),rgba(10,11,13,.82) 55%,rgba(10,11,13,0))}}
    .chips{{display:flex;gap:{vw(18)};margin-bottom:{vw(34)}}}
    .chip{{flex:1;text-align:center;font-size:{vw(30)};font-weight:600;color:#c8ccd4;padding:{vw(22)} 0;border-radius:{vw(18)};background:{SURFACE}}}
    .chip.on{{background:{ACCENT};color:{ONACC}}}
    .row{{display:flex;justify-content:space-between;font-size:{vw(31)};color:#c8ccd4;margin-bottom:{vw(18)}}}
    .row .v{{color:{ACCENT};font-weight:600}}
    .track{{height:{vw(18)};border-radius:{vw(9)};background:#2a2b32;position:relative;margin-bottom:{vw(38)}}}
    .track .fill{{position:absolute;left:0;top:0;bottom:0;width:62%;border-radius:{vw(9)};background:{ACCENT}}}
    .track .knob{{position:absolute;left:62%;top:50%;transform:translate(-50%,-50%);width:{vw(56)};height:{vw(56)};border-radius:50%;background:#fff}}
    .gen{{height:{vw(108)};border-radius:{vw(24)};background:{ACCENT};color:{ONACC};display:flex;align-items:center;justify-content:center;font-size:{vw(38)};font-weight:700}}
    """
    html = f'<div class="ui"><div class="chips">{ch}</div><div class="row"><span>Motion sensitivity</span><span class="v">Birds</span></div><div class="track"><div class="fill"></div><div class="knob"></div></div><div class="gen">Generate trail</div></div>'
    return html, css

def split_card(raw, trail):
    css = f"""
    .splitwrap{{flex:1;width:100%;display:flex;align-items:center;justify-content:center;margin-top:{vw(80)};min-height:0}}
    .scard{{position:relative;height:100%;aspect-ratio:1080/1920;border-radius:{vw(72)};background:#000;padding:{vw(14)};
      box-shadow:0 {vw(50)} {vw(120)} rgba(0,0,0,.7),0 0 0 {vw(1.5)} rgba(255,255,255,.08),0 0 {vw(160)} rgba(92,204,170,.12)}}
    .split{{position:absolute;inset:{vw(14)};border-radius:{vw(60)};overflow:hidden;display:flex;flex-direction:column}}
    .split .half{{flex:1;position:relative;background-size:cover;background-position:center}}
    .split .seam{{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);height:{vw(3)};background:rgba(92,204,170,.6);z-index:2}}
    .tag{{position:absolute;left:{vw(30)};font-size:{vw(28)};font-weight:700;letter-spacing:{vw(3)};text-transform:uppercase;color:#fff;background:rgba(10,11,13,.6);padding:{vw(12)} {vw(22)};border-radius:{vw(14)};z-index:3}}
    """
    html = (f'<div class="splitwrap"><div class="scard"><div class="split">'
            f'<div class="half" style="background-image:url({furl(raw)})"><div class="tag" style="top:{vw(26)}">Before</div></div>'
            f'<div class="seam"></div>'
            f'<div class="half" style="background-image:url({furl(trail)})"><div class="tag" style="bottom:{vw(26)}">After</div></div>'
            f'</div></div></div>')
    return html, css

def steps_block():
    steps = [("Record","Prop your phone.\nCapture a few seconds."),
             ("Tune","Set density & sensitivity\non a live preview."),
             ("Share","Export a loop-ready\nvideo to Photos.")]
    cols = "".join(f'<div class="scol"><div class="num">{i+1}</div><div class="st">{t}</div><div class="sd">{d}</div></div>'
                   for i,(t,d) in enumerate(steps))
    css = f"""
    .cols{{flex:1;display:flex;align-items:center;justify-content:center;gap:{vw(40)};width:100%;margin-top:{vw(40)}}}
    .scol{{flex:1;max-width:{vw(520)};background:{SURFACE};border-radius:{vw(40)};padding:{vw(60)} {vw(46)};
      box-shadow:0 0 0 {vw(1)} rgba(255,255,255,.05);display:flex;flex-direction:column;align-items:center;text-align:center}}
    .scol .num{{width:{vw(118)};height:{vw(118)};border-radius:50%;background:{ACCENT};color:{ONACC};
      display:flex;align-items:center;justify-content:center;font-size:{vw(58)};font-weight:800;margin-bottom:{vw(34)}}}
    .scol .st{{font-size:{vw(54)};font-weight:700}}
    .scol .sd{{font-size:{vw(34)};color:{MUTED};margin-top:{vw(14)};white-space:pre-line;line-height:1.32}}
    .signoff{{display:flex;flex-direction:column;align-items:center;gap:{vw(24)};margin-top:{vw(60)}}}
    .signoff img{{width:{vw(150)};height:{vw(150)};border-radius:{vw(34)};object-fit:cover}}
    .signoff .free{{font-size:{vw(46)};font-weight:700}} .signoff .free .a{{color:{ACCENT}}}
    """
    html = f'<div class="cols">{cols}</div><div class="signoff"><img src="{furl(ICON)}"><div class="free">Free — <span class="a">every effect</span>, no watermark</div></div>'
    return html, css

def build():
    pages = {}
    hero = os.path.join(STILLS,'trail_14.png')

    body = shell(hero) + f'<div class="frame"><div class="eyebrow"><img class="ic" src="{furl(ICON)}">Motion Trails</div><h1>Turn motion into <span class="a">trails</span></h1><div class="sub">Point at something fast. Every pass paints a daylight long-exposure trail over a perfectly still scene.</div>{card(os.path.join(STILLS,"trail_14.png"))}</div>'
    pages["01_hero"] = page(body)

    body = shell(os.path.join(STILLS,'trail_8.png')) + f'<div class="frame"><div class="eyebrow">Automatic detection</div><h1>Fast motion becomes <span class="a">art</span></h1><div class="sub">Birds, cyclists, traffic — fast subjects leave trails. Slow drift like clouds is quietly ignored.</div>{card(os.path.join(STILLS,"trail_8.png"))}</div>'
    pages["02_detect"] = page(body)

    ui, uicss = editor_chrome()
    body = shell(os.path.join(STILLS,'trail_11.png')) + f'<div class="frame"><div class="eyebrow">Live preview</div><h1>Tune it in <span class="a">real time</span></h1><div class="sub">Density, motion sensitivity, fade and colour — dial it in on a live preview, then export.</div>{card(os.path.join(STILLS,"trail_11.png"), ui)}</div>'
    pages["03_tune"] = page(body, uicss)

    sp, spcss = split_card(os.path.join(STILLS,'raw_2.png'), os.path.join(STILLS,'trail_20.png'))
    body = shell(os.path.join(STILLS,'trail_20.png')) + f'<div class="frame"><div class="eyebrow">From clip to loop</div><h1>One locked-off shot, <span class="a">transformed</span></h1><div class="sub">Keep the scene frozen or live underneath. Export a clean, loop-ready video.</div>{sp}</div>'
    pages["04_beforeafter"] = page(body, spcss)

    st, stcss = steps_block()
    body = shell(os.path.join(STILLS,'trail_24.png')) + f'<div class="frame"><div class="eyebrow">Three steps</div><h1>Lock the camera. We do the <span class="a">rest</span>.</h1>{st}</div>'
    pages["05_steps"] = page(body, stcss)
    return pages

def shoot(html_path, out_path, w, h, profile):
    if os.path.exists(out_path): os.remove(out_path)
    p = subprocess.Popen([CHROME,"--headless=new","--disable-gpu","--no-first-run","--no-default-browser-check",
        f"--user-data-dir={profile}","--allow-file-access-from-files","--force-device-scale-factor=1",
        f"--window-size={w},{h}","--hide-scrollbars",f"--screenshot={out_path}",furl(html_path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
            time.sleep(0.5); break
        time.sleep(0.4)
    p.send_signal(signal.SIGKILL); p.wait()

def main():
    pages = build(); profile = tempfile.mkdtemp()
    try:
        for name, html in pages.items():
            hp = os.path.join(WORK, f"ipad_{name}.html")
            with open(hp,"w") as f: f.write(html)
            shoot(hp, os.path.join(OUT129, f"{name}.png"), 2048, 2732, profile)
            shoot(hp, os.path.join(OUT13, f"{name}.png"), 2064, 2752, profile)
            print("rendered", name)
    finally:
        subprocess.run(["pkill","-9","-f",profile], stderr=subprocess.DEVNULL)
        shutil.rmtree(profile, ignore_errors=True)
    from PIL import Image
    for d in (OUT129, OUT13):
        for f in sorted(os.listdir(d)):
            if f.endswith(".png"): print(d.split("/")[-1], f, Image.open(os.path.join(d,f)).size)

if __name__ == "__main__":
    main()
