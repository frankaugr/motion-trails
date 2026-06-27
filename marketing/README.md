# Motion Trails — App Store marketing assets

Promotional App Store "Preview and Screenshots" assets for iPhone, generated from a Pexels stock
clip of black birds circling, run through the app's **own** render engine (not an approximation).

## Deliverables

| Asset | Path | Spec |
|---|---|---|
| App preview video | `preview/MotionTrails-Preview-6.7.mp4` | 1080×1920, H.264, ~23 s, silent AAC track. Valid for iPhone 6.5″/6.7″/6.9″ preview slots. |
| Screenshots — iPhone 6.9″ | `screenshots/iphone-6.9-1320x2868/0{1..5}.png` | 1320×2868 |
| Screenshots — iPhone 6.7″/6.9″ | `screenshots/iphone-6.7-1290x2796/0{1..5}.png` | 1290×2796 |
| Screenshots — iPhone 6.5″ | `screenshots/iphone-6.5-1284x2778/0{1..5}.png` | 1284×2778 |
| Screenshots — iPhone 6.5″ | `screenshots/iphone-6.5-1242x2688/0{1..5}.png` | 1242×2688 |
| Screenshots — iPad 12.9″ | `screenshots/ipad-12.9/0{1..5}.png` | 2048×2732 |
| Screenshots — iPad 13″ | `screenshots/ipad-13/0{1..5}.png` | 2064×2752 |

Folders are named by display slot **and** pixel dimensions. Upload each set into the matching App Store
Connect iPhone/iPad slot. The 6.5″ slot accepts **either** 1284×2778 or 1242×2688 (both provided).
| Processed source (portrait master) | `source/birds_portrait_master.mp4` | 1080×1920, fades removed, center 9:16 crop |
| Trail render (engine output) | `build/birds_trail.mp4` | 1080×1920 — the "after" footage + screenshot stills |
| Bundled in-app demo clip | `../Resources/DemoClip.mp4` | 720×1280, ~6 s — ships in the app |

The preview is a **before → after → endcard** arc: an ordinary locked-off clip, the trails blooming
in over a frozen sky, then a branded endcard. Screenshots: 01 hero · 02 detection · 03 live-tuning
(editor chrome) · 04 before/after · 05 three-steps.

## Source & licensing

- Source: Pexels "Black Birds Flying In Sky" — https://www.pexels.com/video/black-birds-flying-in-sky-13456511/
- The [Pexels License](https://www.pexels.com/license/) permits free **commercial** use, **no attribution
  required**, and **modification**. Our use is a heavily transformed derivative (trimmed, cropped,
  trail-composited) inside App Store marketing. No identifiable people/brands appear; the clip is never
  used in the app's icon/trademark. **Attribution is optional** — credited here as a courtesy only.

## Render settings (natural dark silhouettes)

`contrastMode=.silhouette · motionHorizonSeconds=0.25 · trailFrequency=0.8 · fadeSeconds=0 (persistent)
· backgroundMode=.frozen · colorStyle=.natural`. The bundled demo project is seeded with the same
silhouette settings (see `LibraryView.createDemoProject()`).

## Regenerate

Run from the repo root, in order. (`scripts/` is committed; `work/` is scratch and git-ignored.)

```sh
bash marketing/scripts/01_process_source.sh          # ffmpeg: trim fades, crop portrait, make demo clip
bash marketing/scripts/02_render_trails.sh           # swiftc compile + engine render of the trail effect
bash marketing/scripts/03a_render_overlays.sh        # headless Chrome: endcard + caption PNGs
bash marketing/scripts/03b_assemble_preview.sh       # ffmpeg: assemble the before→after→endcard preview
python3 marketing/scripts/04_screenshots.py          # headless Chrome: 5 iPhone screenshots × 6.7″ + 6.9″
python3 marketing/scripts/04b_screenshots_ipad.py    # headless Chrome: 5 iPad screenshots × 12.9″ + 13″
```

Requires: ffmpeg, swiftc (Xcode toolchain), Google Chrome, python3 + Pillow.

## App Store Connect notes

- Upload the screenshots/preview under **App Store → (version) → Previews and Screenshots**, per device size.
- All four accepted iPhone sizes are provided (6.9″ 1320×2868 / 1290×2796 and 6.5″ 1284×2778 / 1242×2688);
  use whichever the slot you're filling requests. The 1080×1920 preview is accepted across iPhone sizes.
- The target is a **universal** app (`TARGETED_DEVICE_FAMILY = 1,2`), so submission also requires **iPad**
  screenshots — provided in `screenshots/ipad-12.9/` and `ipad-13/`.
- App previews are normally device-captured; this one is intentionally promotional. It is the app's real
  render output plus a short intro/endcard. If review pushes back, trim the 3.5 s raw intro to lead with
  the effect.
