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

`TrailRenderEngine.render(...)` (`Sources/Engine/TrailRenderEngine.swift`) is the orchestrator. It is `async`, cancellable (`Task.checkCancellation()`), and reports fractional progress. The flow per clip:

1. **`BackgroundEstimator`** — builds the static background plate as a **per-pixel temporal median** of up to 19 frames sampled across the clip, skipping leading/trailing dark fade frames (mean luma < 0.06). Median (not mean) is deliberate: it cancels transient moving subjects *and* a minority of dark fade frames. (Note: a stale comment in `TrailRenderEngine` says "mean" — the implementation is median.)
2. **`VideoFrameReader`** — sequentially decodes the source into orientation-normalized BGRA `CIImage` frames (see coordinate conventions below).
3. **`FrameRegistrar`** (optional, off by default) — Vision translational registration against the background to compensate tripod drift.
4. **`MotionMaskBuilder`** — per frame: `differenceBlendMode` (vs background) → `maximumComponent` (collapse RGB change to one magnitude) → `colorThreshold` → morphology **open** (despeckle) → morphology **close** (fill holes) → light blur (feather) → `maskToAlpha`. **The mask is carried in the image's alpha channel**, which is what `CIBlendWithMask` consumes.
5. **`TrailCompositor`** — persistent-replacement compositing via `CIBlendWithMask`: moving pixels (alpha 1) of the current frame overwrite the accumulator; static pixels are preserved. Stateless by design — the engine owns the accumulator.
6. **`VideoFrameWriter`** — encodes each accumulated state to a 1080p-class H.264 MP4 at a fixed output FPS.

`render(output:)` can emit `.mask` instead of `.trail` to visualize the raw mask for tuning.

### Critical invariants — read before touching the engine

- **Coordinate spaces are the most fragile part of the engine (this is where orientation/flip bugs live).** `VideoFrameReader` applies the track's `preferredTransform` and re-anchors to a `(0,0)` origin so downstream filters can treat every frame as upright. `VideoFrameWriter.append` then applies a **vertical flip** (`d:-1, ty:height`) because Core Image's working space is y-up while encoded video treats the first row as the top — and it returns the encoded buffer **mapped back into engine space** so it can be reused as the next accumulator. If you change one side of this, change the other; verify against a source clip that actually carries a non-identity `preferredTransform` (e.g. portrait phone video), not just an upright test clip.
- **The accumulator is re-flattened to a concrete pixel buffer every frame** — that is the purpose of `VideoFrameWriter.append` returning a `CIImage`. Feeding the composite output back in directly would build an unbounded `CIFilter` graph that grows one composite deep per frame and eventually stalls.
- **Stabilization defaults OFF** and `FrameRegistrar` rejects shifts > 2% of the larger dimension. On low-feature scenes (open sky) Vision can lock onto the *moving subjects* and translate the whole frame by their motion, corrupting the static background. Don't re-enable it by default.
- **Leading dark fade-in frames are skipped** in both the background estimate and the render loop. Using frame 0 as the background breaks on clips that open on a black fade (frame 0 = RGB 0,0,0) — the whole scene reads as motion and the mask inverts.
- **One shared Metal `CIContext`** (`SharedRender.ciContext`) is reused across diff/threshold/morphology/composite/encode. `CIContext` creation is expensive and each holds its own GPU caches — don't create per-frame contexts.

### RenderSettings

`RenderSettings` exposes two neutral `0...1` sliders (`sensitivity`, `minMotionSize`) plus a stabilization toggle, and derives the concrete Core Image tunables (`differenceThreshold`, `morphologyRadius`) so the UI never touches CI internals. Add user controls here, mapping them to derived tunables, rather than threading raw pixel values through the UI.

## UI layer

A thin SwiftUI `NavigationStack` harness in `Sources/UI/` and `Sources/App/`:

`ImportView` (PhotosPicker → copies the clip to a temp file) → `RenderView` (preview + sliders + `TrailRenderEngine` invocation with progress/cancel) → `ResultView` (play + save to Photos / `ShareLink`). Navigation is driven by `navigationDestination(item:)` using the `VideoRef` wrapper (a `URL` isn't `Identifiable` on its own). The render runs in a cancelled-on-disappear `Task`; progress is marshalled to `@MainActor`.

## Roadmap context

Phase 1 (the engine + harness) is built and verified. The next work is Phase 2 MVP (spec §19): controlled capture + stability pre-check, project storage/library, edit re-render, crop presets, watermark, free-tier length limit + StoreKit gating. Phase 3 is premium features (§8).
