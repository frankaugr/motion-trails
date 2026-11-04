# Motion Trails — App Store marketing assets

Promotional "Previews and Screenshots" assets for iPhone and iPad, generated from Pexels stock clips
run through the app's **own** render engine (not an approximation), plus the text metadata
(`appstore-metadata.md`) and the App Review notes (`appstore-review-notes.md`).

## Deliverables

The **app preview video is the hero** — it autoplays before the screenshots on the product page and
in search results — so it opens on the strongest footage (the sunset geese).

| Asset | Path | Spec |
|---|---|---|
| **App preview video (hero)** | `preview/MotionTrails-Preview-Hero-886x1920.mp4` | 886×1920, H.264, 21 s, silent AAC. Sunset geese trail blooms in → editor "Tune it live" beat → grey-sky flock → endcard (`scripts/06_preview_hero.sh`). Poster frame ≈ 5.5 s. |
| App preview video (alt, flock only) | `preview/MotionTrails-Preview-Trail-886x1920.mp4` | 886×1920, 27 s. The grey-sky render with captions (`scripts/05_trail_only_preview.sh`). Superseded by the hero cut. |
| App preview video (old, 1080) | `preview/MotionTrails-Preview-6.7.mp4` | 1080×1920 — **not uploadable** (ASC accepts only 886×1920 / 1920×886 for iPhone preview slots). Kept for reference. |
| Screenshots — iPhone 6.9″ | `screenshots/iphone-6.9-1320x2868/0{1..6}_*.png` | 1320×2868 |
| Screenshots — iPhone 6.7″/6.9″ | `screenshots/iphone-6.7-1290x2796/0{1..6}_*.png` | 1290×2796 |
| Screenshots — iPhone 6.5″ | `screenshots/iphone-6.5-1284x2778/0{1..6}_*.png` | 1284×2778 |
| Screenshots — iPhone 6.5″ | `screenshots/iphone-6.5-1242x2688/0{1..6}_*.png` | 1242×2688 |
| Screenshots — iPad 12.9″ | `screenshots/ipad-12.9/0{1..6}_*.png` | 2048×2732 |
| Screenshots — iPad 13″ | `screenshots/ipad-13/0{1..6}_*.png` | 2064×2752 |
| Source — grey-sky birds (portrait master) | `source/birds_portrait_master.mp4` | 1080×1920, 24.5 s, fades removed, centre 9:16 crop |
| Source — sunset geese (portrait master) | `source/sunset_geese_master.mp4` | 1080×1920, 10.4 s, 2× speed, 30 fps |
| Source — real-device captures | `source/captures/ipad_*.png` | 1640×2300 frames from a physical-iPad screen recording (status bar cropped): editor, Motion panel, result, capture, library |
| Trail renders (engine output) | `build/*.mp4` | git-ignored; regenerate with `02_render_trails.sh` + `02b_render_extras.sh` |
| Bundled in-app demo clip | `../Resources/DemoClip.mp4` | 720×1280, ~6 s — ships in the app |

Screenshot folders are named by display slot **and** pixel dimensions; upload each set into the
matching App Store Connect slot. The 6.5″ slot accepts **either** 1284×2778 or 1242×2688.

### The six screens (same story on iPhone and iPad)

| # | File | Headline | Imagery |
|---|---|---|---|
| 1 | `01_hero` | Turn motion into trails | sunset geese trail |
| 2 | `02_beforeafter` | One locked-off shot, transformed | raw sunset frame / finished trail, split |
| 3 | `03_tune` | Tune it in real time | sunset trail + the real **Trails** panel (Density, Generate). **iPad: a real device capture** of the editor |
| 4 | `04_detect` | Fast motion becomes art | dense grey-sky flock + the **Motion** panel (Subject contrast, Speed threshold) |
| 5 | `05_effects` | Fade, colour and sway | trail still + the **Effects** panel (Fade, Color, Handheld camera, Depth parallax). Switches to the age-gradient render once `02b` has produced it |
| 6 | `06_steps` | Lock the camera. We do the rest. | Record · Tune · Share, feature pills, trail strip, "Every effect included" |

The recreated editor chrome mirrors `RenderView` (pill chip row, raised panel, "✦ Generate · N s clip"
bar) so the screenshots show the UI a reviewer actually meets. Only the first three screenshots show in
search results — they carry the look, the transformation and the app.

## Sources & licensing

All three clips are from Pexels under the [Pexels License](https://www.pexels.com/license/): free
**commercial** use, **modification** allowed, **no attribution** required. Our use is a heavily
transformed derivative (trimmed, cropped, sped up, trail-composited) inside App Store marketing; no
identifiable people or brands appear, and none of the footage is used in the icon/trademark.
Credited here as a courtesy only.

- Grey-sky birds — "Black Birds Flying In Sky", https://www.pexels.com/video/black-birds-flying-in-sky-13456511/
  (also the bundled demo clip and the **only** footage inside the app binary).
- Sunset geese — Pexels video 14515019, https://www.pexels.com/video/14515019/ (1080×1920, 24 fps).
- White storks on blue sky — Pexels video 13313562, https://www.pexels.com/video/13313562/ (1080×1920,
  60 fps). Optional variety clip; not in the current set.

## Render settings (natural dark silhouettes)

`contrastMode=.silhouette · motionHorizonSeconds=0.25 · trailFrequency=0.8 · fadeSeconds=0 (persistent)
· backgroundMode=.frozen · colorStyle=.natural` for both the grey-sky and sunset renders. The gradient
variant adds `colorStyle=.ageGradient · gradientShiftSeconds=3 · fadeSeconds=2`. The bundled demo project
is seeded with the silhouette settings (see `LibraryView.createDemoProject()`).

## Regenerate

Run from the repo root, in order. (`scripts/` is committed; `work/` and `build/` are scratch and
git-ignored.) Steps 2/2b compile the engine with `swiftc`; everything else is ffmpeg + headless Chrome.

```sh
bash marketing/scripts/01_process_source.sh          # ffmpeg: grey-sky master + the bundled demo clip
bash marketing/scripts/01b_process_extra_sources.sh  # ffmpeg: sunset geese (2×) + storks masters
bash marketing/scripts/02_render_trails.sh           # swiftc + engine: build/birds_trail.mp4
bash marketing/scripts/02b_render_extras.sh          # swiftc + engine: sunset, age-gradient, storks renders
bash marketing/scripts/03a_render_overlays.sh        # headless Chrome: endcard + caption PNGs
python3 marketing/scripts/04_screenshots.py          # cuts stills, renders 6 iPhone screens × 4 sizes
python3 marketing/scripts/04b_screenshots_ipad.py    # 6 iPad screens × 2 sizes (uses the real capture)
bash marketing/scripts/06_preview_hero.sh            # ffmpeg: the hero app preview (886×1920)
```

Older alternates: `03b_assemble_preview.sh` (before→after arc, 1080 — not uploadable as-is) and
`05_trail_only_preview.sh` (flock-only 886 cut).

Requires: ffmpeg, swiftc (Xcode toolchain), Google Chrome, python3 + Pillow.

## App Store Connect notes

- Upload under **App Store → (version) → Previews and Screenshots**, per device size. Put the preview
  video first, set its poster frame around 5.5 s, then screenshots 01→06 in order.
- All four accepted iPhone sizes are provided; use whichever the slot you're filling requests.
  **App previews must be exactly 886×1920 (portrait) or 1920×886 (landscape)** for the iPhone slots —
  ASC rejects 1080×1920 at upload.
- The target is a **universal** app (`TARGETED_DEVICE_FAMILY = 1,2`), so iPad screenshots are required —
  provided in `screenshots/ipad-12.9/` and `ipad-13/`. The iPad `03_tune` is a real device capture.
- The preview is intentionally promotional (the app's real render output plus an editor beat, captions
  and an endcard). If review pushes back on it, the editor beat and the real iPad captures in
  `source/captures/` are the material for a more literal cut.
