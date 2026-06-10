# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Motion Trails** is a native iOS/iPadOS app (SwiftUI) that turns a short fixed-camera clip into a video where moving subjects leave realistic trails over a static background. The full product spec is `MOTION_TRAILS_IOS_APP_SPEC.md`; the spec's section numbers (`§11.4`, etc.) are cited throughout the source. The render engine (`Sources/Engine/`) is the heart of the app and its main technical risk — the SwiftUI layer is a thin harness around it.

Locked decisions: prototype-first, iOS 18 minimum deployment, Core Image–first render engine, Swift 5 language mode, XcodeGen for project generation.

## Build, run, test

The Xcode project is **generated** from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`/opt/homebrew/bin/xcodegen`). `MotionTrails.xcodeproj` is a build artifact — do **not** hand-edit it. After changing `project.yml`, or adding/removing/renaming source files, regenerate:

```sh
xcodegen generate
```

Build (scheme `MotionTrails`):

```sh
# Compile-check for a device without signing/simulator
xcodebuild -project MotionTrails.xcodeproj -scheme MotionTrails \
  -destination 'generic/platform=iOS' -configuration Debug build

# Run in the simulator (iOS 26 runtimes are installed)
xcodebuild -project MotionTrails.xcodeproj -scheme MotionTrails \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### Verifying the engine headlessly (the primary test loop)

There is **no XCTest suite**. The engine is the thing that needs verifying, and every API it uses (AVFoundation, Core Image, Vision) is cross-platform, so it is fastest to drive it from a tiny macOS `main.swift` harness that renders a real clip and dumps frames/output — no simulator, no app launch:

```sh
swiftc -swift-version 5 Sources/Engine/*.swift /path/to/harness/main.swift -o /tmp/trailcheck && /tmp/trailcheck
```

Engine bugs in this app are almost always **temporal/whole-frame** artifacts (orientation flips, registration jitter, mask inversion across a fade-in). A single still frame routinely looks fine while the video is wrong — **dump consecutive frames and inspect the actual output MP4**, don't judge from one frame.

## Render pipeline architecture

`TrailRenderEngine.render(...)` (`Sources/Engine/TrailRenderEngine.swift`) is the orchestrator. It is `async`, cancellable (`Task.checkCancellation()`), and reports fractional progress plus an optional coarse `RenderStage` callback (`.analyzing` during the plate pass → `.rendering`); the estimator's sampling is mapped into the first ~10% of the progress range so the bar moves from the very start instead of stalling at 0%. The flow per clip:

1. **`BackgroundEstimator`** — builds the static background plate as a **per-pixel temporal median** of up to 19 frames sampled across the clip, skipping dark fade frames (mean luma < 0.06). Sampling is **random access** via `AVAssetImageGenerator` (≤19 seeks with a 0.2 s sync-frame tolerance), *not* a sequential decode — so a render decodes the clip only once (the main pass). The generator's `appliesPreferredTrackTransform` output is upright-in-CI exactly like `VideoFrameReader`'s frames, keeping the plate and frames in one orientation space. Median (not mean) is deliberate: it cancels transient moving subjects *and* a minority of dark fade frames. **The plate is no longer the detection reference** (detection is temporal — see §4); it is the clean **display plate** the trails composite over, and the seed for the accumulator. (Note: a stale comment in `TrailRenderEngine` says "mean" — the implementation is median.)
2. **`VideoFrameReader`** — sequentially decodes the source into orientation-normalized BGRA `CIImage` frames (see coordinate conventions below).
3. **`FrameRegistrar`** (optional, off by default) — Vision translational registration against the background to compensate tripod drift. Applied at decode time, before a frame enters the delay-line, so temporal differences are taken between aligned frames.
4. **`MotionMaskBuilder` — temporal (velocity) detection.** Detection keys on **how fast** something moves, not how it differs from a long-term plate: the discriminator this app is built for (fast birds) vs. what it must reject (slow cloud drift, a swaying tree, light changes). Per frame the signal is `min(|f_t − f_{t−K}|, |f_t − f_{t+K}|)` — the per-channel difference (collapsed to its max channel for the default `.any`) against the frames **K positions before and after** (`settings.motionHorizonFrames`). Slow drift is ~unchanged over ±K and cancels; a fast subject displaces fully and survives. The symmetric `min` localizes the subject at its position at *t* (it removes the trailing "ghost" each one-sided difference leaves); a neighbour that is missing (clip ends) or a dark fade frame is dropped, and the lone remaining side is used. The contrast modes still pick *what kind* of difference counts (`.any` full-colour; `.silhouette`/`.highlight` luminance darkening/brightening with a `tonemap` curve; `.colour` chroma) but operate on the temporal pair, not the plate. Tail: `colorThreshold` → morphology **open** (small despeckle, radius ~2 — large radii rounded small birds into dots) → morphology **close** (fill holes) → light blur (feather) → `maskToAlpha`. **The mask is carried in the image's alpha channel**, which is what `CIBlendWithMask` consumes. A legacy single-reference `makeMask(current:background:)` overload is kept for the headless harness only.
5. **`TrailCompositor`** — persistent-replacement compositing via `CIBlendWithMask`: moving pixels (alpha 1) of the current frame overwrite the accumulator; static pixels are preserved. Stateless by design — the engine owns the accumulator.
6. **`VideoFrameWriter`** — encodes each accumulated state to a 1080p-class H.264 MP4 at a fixed output FPS.

`render(output:)` can emit `.mask` instead of `.trail` to visualize the raw mask for tuning.

### Critical invariants — read before touching the engine

- **Coordinate spaces are the most fragile part of the engine (this is where orientation/flip bugs live).** `VideoFrameReader` is the *single* place orientation is normalized: it applies the track's `preferredTransform` and re-anchors to a `(0,0)` origin so every downstream stage — masking, compositing, the background plate, the watermark, and the encode — operates on an already-upright, y-up image. The encode (`VideoFrameWriter.makeFrameBuffer`) is therefore a **straight passthrough with no flip**: `CIContext.render(_:to:)` preserves visual orientation into the pixel buffer, so visual-bottom is low `y` everywhere (that's why the watermark is placed at `y ≈ 0`). Do **not** reintroduce a vertical flip on the encode — an earlier `d:-1, ty:height` flip there inverted *every* export (the flying-birds clip rendered with the sky at the bottom), and the watermark was pre-flipped to mask it, so the two bugs cancelled only for the watermark. Verify orientation against a clip with a clear up/down (sky vs. water) **and** one carrying a non-identity `preferredTransform` (portrait phone video) — and judge from the encoded MP4, not a single `createCGImage`/`toBitmap` still, whose row order can disagree with the encode path. Corollary: any coordinates sourced from the UI are **top-left origin** (`MaskEditorView` ignore-region rects) and must be y-flipped into the engine's y-up space — `IgnoreMaskBuilder` does this now that the encode no longer flips. When you add a feature that places UI-specified geometry into a frame, flip its `y`.
- **The accumulator is re-flattened to a concrete pixel buffer every (snapshot) frame** via `PixelBufferFlattener`. Feeding the composite output back in directly would build an unbounded `CIFilter` graph that grows one composite deep per frame and eventually stalls. (The engine owns and flattens the accumulator itself — `VideoFrameWriter` no longer returns a "mapped-back" image; its write is split into `makeFrameBuffer` (sync render) + `append` (async encode), see the memory invariant below.)
- **The per-frame render loop body runs inside an explicit `autoreleasepool`**, and the encode-side `await writer.append(...)` is kept *outside* it (you can't suspend across a pool body — hence the `makeFrameBuffer`/`append` split). Core Image and AVFoundation hand back autoreleased IOSurfaces / `CMSampleBuffer`s every frame; without a per-frame drain they accumulate across a long clip until iOS jetsams the app — a 44 s / ~1300-frame clip was the original repro. **The macOS headless harness does *not* reproduce this**: the Swift-concurrency executor drains around each `await` there and the macOS memory ceiling is far higher, so a regression here stays invisible to the harness. Reason about per-frame allocation lifetimes directly; don't rely on the harness to catch it.
- **Temporal detection holds a bounded ±K delay-line of decoded frames** (`window`, at most `2K+1` flattened frames; K is small — ~7 at 30 fps). Each decoded frame is rendered into its **own** GPU buffer via a dedicated `frameFlattener` (separate pool from the accumulator's) *before* being buffered, because `VideoFrameReader` vends recycled sample buffers (`alwaysCopiesSampleData = false`) whose memory would otherwise be reused under the held references. The window is the only cross-frame state besides the accumulator/age-map, and it is bounded regardless of clip length, so the long-clip memory invariant holds — but it means the engine now decodes K frames *ahead* of the centre it's writing (output is delayed by K, not reordered).
- **Stabilization defaults OFF** and `FrameRegistrar` rejects shifts > 2% of the larger dimension. On low-feature scenes (open sky) Vision can lock onto the *moving subjects* and translate the whole frame by their motion, corrupting alignment. Don't re-enable it by default. (With temporal detection a drifting tripod would otherwise make *every* pixel differ between ±K frames — registration before the delay-line is what keeps that from reading as motion when stabilization is on.)
- **Leading dark fade-in frames are skipped** as render centres (and in the background estimate). A dark frame used as a temporal *neighbour* would flood the difference (bright frame vs. black ≈ whole-frame motion), so a non-bright neighbour is dropped and the clean side is used — each window frame carries a `bright` flag for this. Don't take a temporal difference across a fade boundary without that guard.
- **One shared Metal `CIContext`** (`SharedRender.ciContext`) is reused across diff/threshold/morphology/composite/encode. `CIContext` creation is expensive and each holds its own GPU caches — don't create per-frame contexts.

### RenderSettings

`RenderSettings` drives detection from a single high-level `contrastMode` enum (`.any`/`.silhouette`/`.highlight`/`.colour`); each case **bundles** the concrete `differenceThreshold` (`morphologyRadius` is now a small constant ~2 — see §4), and `RenderSettings.differenceThreshold`/`morphologyRadius` delegate to it. There is intentionally no raw sensitivity/min-size slider in the UI. Add user controls here, mapping them to derived tunables, rather than threading raw pixel values through the UI.

**`motionHorizonSeconds` is the velocity knob** (the surfaced "Motion sensitivity" slider). It's the K in §4's temporal difference, in *seconds of source* (frame-rate-independent; `motionHorizonFrames(fps:)` converts). Smaller = stricter (only the fastest subjects leave trails); larger = catches slower motion but lets slow drift back in.

**`backgroundMode` is the Frozen/Live display toggle** — what the trails composite *over*, a pure display choice (detection is temporal and independent of it). `.frozen` = the median plate (static-scene look); `.live` = the current frame, so clouds/foliage keep moving under the trails. It only swaps the composite backdrop (`staticBackground` ↔ `current` in the engine; plate ↔ last-frame proxy in the preview), so it's a cheap `recompose`, not in `maskKey`/`cacheKey`. The enum was repurposed from the old `.static`/`.slowUpdate`; `.frozen` keeps rawValue `"static"` for manifest compatibility and the removed `.slowUpdate` decodes tolerantly to the default. (The old `.slowUpdate` adaptive-background idea is obsolete — temporal detection already ignores slow background change, so `.live` can show the raw current frame without polluting detection.)

**Trail density is time-based, not clip-proportional.** `trailFrequency` (0…1) maps to `snapshotsPerSecond` (seconds of *source*), and `snapshotCount(durationSeconds:)` multiplies that by the clip length — so "Dense" leaves silhouettes at the same temporal spacing on a 5 s clip and a 50 s clip. (The old model spread a fixed ≤48 count across the whole clip, which made long clips sparse.) The render's snapshot count is uncapped; the live preview (`TrailPreviewRenderer`) caps cached proxy layers at `maxSnapshots`, so on a long, dense clip the **preview saturates** (can't show denser than its cache) while the render keeps getting denser — expected, not a bug.

**Ignore regions play the live video, they don't freeze.** `IgnoreMaskBuilder` keeps those areas out of the *motion mask* (no trails form there), and the render loop then blends the **current frame** (not the static plate) back into them via the keep-mask, so excluded water/foliage keeps moving normally in the output.

## UI layer

A SwiftUI `NavigationStack` app in `Sources/UI/` and `Sources/App/`, **dark-first** (`RootView` sets `.preferredColorScheme(.dark)`): tokens live in `Theme` (`Sources/UI/Theme.swift` — canvas/surface colors, radii, centralized `Theme.Haptics`) and small shared components in `Components.swift` (`PrimaryButtonStyle`, `UpsellChip` — the only watermark/premium upsell affordance — `LoopingPlayerView`, and the animated `TrailMotif` brand mark used by onboarding/paywall/empty state). The accent is the asset catalog's `AccentColor` (trail teal).

Flow: `LibraryView` (project grid: rename / play-latest-export / `ExportsSheet` manage-exports / delete via context menu; async storage footer + downsampled thumbnails; first-run `OnboardingView` cover that can seed a demo project from `SampleClipFactory`) → `RenderView` → result *in place*. Capture is a full-screen cover; its project handoff uses the cover's `onDismiss` (no timing hacks).

**`RenderView` is a canvas-first editor, not a Form.** The preview canvas stays pinned at the top; below it a chip row switches one control group at a time (Trails / Motion / Scene / Crop / Effects) above a persistent Generate bar. Rendering overlays the canvas (stage label + progress, cancel in the bottom bar), and on completion the **same canvas swaps to a looping player** (`phase == .result`) with Save-to-Photos/Share — there is no separate `ResultView`. Press-and-hold the preview to compare with the plain source frame (`preview.sourceImage`); the Crop chips dim the area the selected aspect will discard, live. **Settings persist as they change** (debounced `onChange(of: settings)` + a final write `onDisappear`) — never only at render time. The single `onChange(of: settings)` handler diffs `maskKey` (contrast mode + horizon + ignore regions) to decide re-prepare vs. cheap `recompose`. After a render, the temp output is deleted once `addExport` has copied it into the project.

**Live preview (`TrailPreviewRenderer`).** "Preparing preview" decodes the clip **once** at proxy resolution (≤480px) and cuts each snapshot into a subject layer — a single decode pass because the clip decode dominates the cost (the old two-pass version decoded it twice). It runs the **same temporal mask the engine does**, via a bounded ±K proxy **delay-line** (a ring of ~`2K+2` recent proxy frames): each snapshot's layer is cut once its `+K` look-ahead frame is decoded, using the *true* proxy frames K positions before/after — so the motion-sensitivity (`motionHorizonSeconds`) is reflected **exactly**, not approximated. Ignore regions are **baked into the layers** (the engine's keep-mask, applied at proxy scale) and are therefore part of `cacheKey`/`maskKey`. The plate is a proxy temporal median of the snapshot frames, used only as the `recompose` composite base. **`recompose` carries full engine parity for the display-time settings**: frequency, blend, Frozen/Live backdrop, *fade* (per-layer opacity `ageDecay^(framesSinceSnapshot)` — exactly the engine's age-map blend at the final frame) and *age-gradient color* (per-layer tint along `TrailColorizer`'s shared endpoints) — premium users are not tuning blind. The result is **cached to disk** under `<project-dir>/preview.cache/<keyhash>/` (one subdirectory per settings combination, **LRU-pruned to 4 entries**, so revisiting a recent slider value reloads instantly), keyed by `cacheKey` (contrast mode + horizon + ignore regions + proxy params + `cacheVersion`). Reopening a project loads the cache (~15× faster) instead of recomputing. **Bump `cacheVersion` whenever the preview pipeline or mask algorithm changes** (v4: ignore-region baking + per-key subdirectories), or stale caches will load.

**`SampleClipFactory`** (`Sources/Engine/`, so the headless harness can use it) synthesizes the 5 s demo clip — gradient sky, four sine-path "birds" — that onboarding and the library's empty state offer as a guaranteed-good first project. It is also the deterministic source for headless verification: generate → estimate → render → decode the output MP4 and assert trail accumulation.

## Roadmap context

Phase 1 (the engine + harness) is built and verified. The next work is Phase 2 MVP (spec §19): controlled capture + stability pre-check, project storage/library, edit re-render, crop presets, watermark, free-tier length limit + StoreKit gating. Phase 3 is premium features (§8).
