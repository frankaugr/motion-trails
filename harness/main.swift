import AVFoundation
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import Foundation

// Headless verification harness for the renderer performance changes (see CLAUDE.md):
//   1. Pooled-CVPixelBuffer flatten replacing createCGImage  → check: no color drift across frames.
//   2. Parallelized background median (concurrentPerform)    → check: median recovers the static
//      plate (moving subject removed) uniformly across all rows (catches parallel row corruption).
//   3. Proxy-resolution preview mask                          → exercised via SubjectLayerExtractor.
//   5. Real-time output: frame-rate math + a 60 fps source keeps its duration (it used to export
//      at half speed — every source frame was stamped at a fixed 30 fps).
//   6. Storage precision: age maps decay to the closed-form value in half-float (8-bit froze long
//      fades at a residual), and dark tones keep their levels in sRGB image buffers (8-bit linear
//      collapsed sRGB 0…50 to ~9 levels).
//   7. Preview coverage: on a 150-frame clip the preview's trail reaches the end of the subject's
//      path, like the export (the old round-down stride stopped the preview at frame 96).
//
// It synthesizes clips (uniform colored background + a white square sweeping the mid band, with a
// black fade-in), runs BackgroundEstimator, TrailRenderEngine and TrailPreviewRenderer, inspects
// pixels, dumps the first and last output frames as PNGs, and prints timings. Run with:
//
//   swiftc -swift-version 5 Sources/Engine/*.swift harness/main.swift -o /tmp/trailcheck && /tmp/trailcheck

let ctx = SharedRender.ciContext
let tmp = FileManager.default.temporaryDirectory
let srcURL = tmp.appendingPathComponent("harness-src.mp4")

// Clip geometry.
let W = 256, H = 256, N = 64, fadeFrames = 5, square = 40
// Uniform background with distinct per-channel values (so a per-channel color drift is visible).
let bgR: CGFloat = 100/255, bgG: CGFloat = 150/255, bgB: CGFloat = 200/255

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print((condition ? "  ✅ PASS  " : "  ❌ FAIL  ") + message)
    if !condition { failures += 1 }
}
func approx(_ a: Int, _ b: Int, _ tol: Int) -> Bool { abs(a - b) <= tol }

// MARK: - Synthetic clip

func makePixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb!
}

/// Frame `i` of an `n`-frame clip: black for the fade-in, then the plate with a `side`-px white
/// square sweeping left → right across the (vertically centred) mid band.
func drawFrame(_ i: Int, frames n: Int = N, side: Int = square) -> CVPixelBuffer {
    let pb = makePixelBuffer()
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    let cg = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H,
                       bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)!
    if i < fadeFrames {
        cg.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
    } else {
        cg.setFillColor(CGColor(red: bgR, green: bgG, blue: bgB, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let t = Double(i - fadeFrames) / Double(n - fadeFrames - 1)
        let x = Int(t * Double(W - side))
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: x, y: (H - side) / 2, width: side, height: side))
    }
    return pb
}

func synthesizeClip(to url: URL = srcURL, frames n: Int = N, fps: Int32 = 30,
                    side: Int = square) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: W, AVVideoHeightKey: H
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<n {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        adaptor.append(drawFrame(i, frames: n, side: side), withPresentationTime: CMTime(value: Int64(i), timescale: fps))
    }
    input.markAsFinished()
    await withCheckedContinuation { c in writer.finishWriting { c.resume() } }
}

// MARK: - Pixel inspection

func render(_ image: CIImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        ctx.render(image, toBitmap: p.baseAddress!, rowBytes: w * 4,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    return buf
}
func toRGBA(_ image: CIImage) -> [UInt8] { render(image, W, H) }
func pixel(_ buf: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let i = (y * W + x) * 4
    return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
}
func savePNG(_ image: CIImage, _ name: String) {
    guard let cgImage = ctx.createCGImage(image, from: CGRect(x: 0, y: 0, width: W, height: H)) else { return }
    let url = tmp.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    print("       wrote \(url.path)")
}

func readFrames(_ url: URL) async throws -> [CIImage] {
    let reader = try await VideoFrameReader(url: url)
    try reader.start()
    var frames: [CIImage] = []
    while let f = try reader.nextFrame() {
        frames.append(f.cropped(to: CGRect(x: 0, y: 0, width: W, height: H)))
    }
    return frames
}

// MARK: - Tests

func run() async throws {
    print("Synthesizing \(N)-frame \(W)x\(H) clip (\(fadeFrames) black fade-in frames)…")
    try await synthesizeClip()

    // ---- Test 1: background median (parallel) ----
    print("\n[1] Background median — parallel concurrentPerform")
    let t0 = Date()
    let bg = try await BackgroundEstimator().estimate(url: srcURL, cropRect: CGRect(x: 0, y: 0, width: W, height: H))
    let bgMs = Date().timeIntervalSince(t0) * 1000
    let bgBuf = toRGBA(bg)
    let (r0, g0, b0) = pixel(bgBuf, 4, 4)                  // corner reference
    print(String(format: "       estimate: %.1f ms · reference pixel = (%d,%d,%d)", bgMs, r0, g0, b0))

    // The moving white square must be gone everywhere (median rejects the minority subject) and the
    // plate must be uniform across the whole frame — sampling a grid stresses every row written by a
    // different concurrentPerform iteration.
    var uniform = true, subjectGone = true
    for gy in stride(from: 2, to: H, by: 17) {
        for gx in stride(from: 2, to: W, by: 17) {
            let (r, g, b) = pixel(bgBuf, gx, gy)
            if !(approx(r, r0, 6) && approx(g, g0, 6) && approx(b, b0, 6)) { uniform = false }
            if r > 220 && g > 220 && b > 220 { subjectGone = false }   // would be white if subject leaked
        }
    }
    check(subjectGone, "moving subject removed from background plate (no white pixels)")
    check(uniform, "background plate uniform across all rows (no parallel row corruption)")
    check(r0 < 220 && g0 < 220 && b0 < 220, "background is the static plate color, not the white square")

    // ---- Test 2: render + flatten color stability (default settings) ----
    print("\n[2] Render (default settings) — pooled-buffer flatten, no color drift")
    var settings = RenderSettings()
    let t1 = Date()
    let outURL = try await TrailRenderEngine().render(sourceURL: srcURL, settings: settings)
    let renderMs = Date().timeIntervalSince(t1) * 1000
    let frames = try await readFrames(outURL)
    print(String(format: "       render: %.1f ms · %d output frames", renderMs, frames.count))
    check(frames.count >= (N - fadeFrames) - 2, "output frame count ≈ processed source frames")

    guard let first = frames.first, let last = frames.last else {
        check(false, "output has frames"); return
    }
    savePNG(first, "harness-first.png")
    savePNG(last, "harness-last.png")
    let firstBuf = toRGBA(first)
    let lastBuf = toRGBA(last)

    // Static region: the top band (y≈10) is never touched by the mid-band square, so it must stay
    // equal to the seeded background from the first frame all the way to the last. A flatten that
    // drifted color across the accumulator's hundreds of round-trips would show up here.
    let staticY = 10
    var maxDrift = 0
    for sx in stride(from: 4, to: W, by: 12) {
        let (fr, fg, fb) = pixel(firstBuf, sx, staticY)
        let (lr, lg, lb) = pixel(lastBuf, sx, staticY)
        maxDrift = max(maxDrift, abs(fr - lr), abs(fg - lg), abs(fb - lb))
    }
    print("       max static-region drift first→last frame: \(maxDrift)/255")
    check(maxDrift <= 6, "no color drift in static region across the whole render (≤6/255)")

    // Trail persistence: a pixel on the square's mid path (centre of the mid band) should be bright
    // in the last frame — the silhouette was stamped into the trail and never overwritten. Probe
    // mid-path, not the path's start: temporal detection deliberately tapers off over the first ~K
    // frames (the ±K pair shrinks toward the clip edge and is used both-or-nothing), so with K = 8
    // the square's opening positions (x < ~40) never enter the trail. The old x = 20 probe predated
    // temporal detection and had been failing since it landed.
    let trailX = W / 2
    let (tr, tg, tb) = pixel(lastBuf, trailX, H / 2)
    let (br, bg2, bb) = pixel(lastBuf, trailX, staticY)   // background at the same column
    print("       trail pixel (\(trailX),\(H/2)) = (\(tr),\(tg),\(tb)) vs background = (\(br),\(bg2),\(bb))")
    check(tr + tg + tb > (br + bg2 + bb) + 80, "trail silhouette persisted (brighter than background)")

    // ---- Test 3: render with fade on (exercises per-frame ageMap flatten path) ----
    print("\n[3] Render (fade enabled) — per-frame age-map flatten")
    settings.fadeSeconds = 2.0
    let t2 = Date()
    let fadeURL = try await TrailRenderEngine().render(sourceURL: srcURL, settings: settings)
    let fadeMs = Date().timeIntervalSince(t2) * 1000
    let fadeFramesOut = try await readFrames(fadeURL)
    print(String(format: "       render: %.1f ms · %d output frames", fadeMs, fadeFramesOut.count))
    check(fadeFramesOut.count >= (N - fadeFrames) - 2, "fade render completes with expected frame count")

    if let fLast = fadeFramesOut.last {
        let fb = toRGBA(fLast)
        var drift = 0
        let ff = toRGBA(fadeFramesOut.first!)
        for sx in stride(from: 4, to: W, by: 12) {
            let (a, b, c) = pixel(ff, sx, staticY)
            let (d, e, f) = pixel(fb, sx, staticY)
            drift = max(drift, abs(a - d), abs(b - e), abs(c - f))
        }
        check(drift <= 6, "no static-region drift with fade/per-frame flatten enabled (≤6/255)")
    }

    // ---- Test 4: proxy-resolution mask (preview path) ----
    print("\n[4] Proxy-resolution subject mask — SubjectLayerExtractor radiusScale")
    let proxyScale: CGFloat = 0.5
    let pw = W / 2, ph = H / 2
    let pRect = CGRect(x: 0, y: 0, width: pw, height: ph)
    let scaleT = CGAffineTransform(scaleX: proxyScale, y: proxyScale)
    // Source frame ~34 has the square centered.
    let srcFrames = try await readFrames(srcURL)
    let midFrame = srcFrames[min(34, srcFrames.count - 1)]
    let frameProxy = midFrame.transformed(by: scaleT).cropped(to: pRect)
    let bgProxy = bg.transformed(by: scaleT).cropped(to: pRect)
    let layer = SubjectLayerExtractor().subjectLayer(frame: frameProxy, background: bgProxy,
                                                     settings: RenderSettings(), radiusScale: proxyScale)
    // Composite the cut-out over black: subject region should be bright, empty region should be black.
    let onBlack = layer.composited(over: CIImage(color: .black).cropped(to: pRect))
    let layerBuf = render(onBlack, pw, ph)
    func p(_ b: [UInt8], _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * pw + x) * 4; return (Int(b[i]), Int(b[i + 1]), Int(b[i + 2]))
    }
    let (cx, cy, cz) = p(layerBuf, pw / 2, ph / 2)        // square center → bright subject
    let (ex, ey, ez) = p(layerBuf, 4, 4)                  // corner → outside subject, stays black
    print("       proxy \(pw)x\(ph) · subject pixel = (\(cx),\(cy),\(cz)) · empty pixel = (\(ex),\(ey),\(ez))")
    check(cx > 180 && cy > 180 && cz > 180, "subject cut out at proxy resolution (bright at square)")
    check(ex < 40 && ey < 40 && ez < 40, "non-subject region transparent at proxy resolution")

    // ---- Test 5: real-time output timing ----
    print("\n[5] Real-time output — decimate fast sources, keep slow ones at their own rate")
    let rates: [(source: Double, expected: Int)] = [(24, 24), (25, 25), (29.97, 30), (30, 30),
                                                    (50, 25), (59.94, 30), (60, 30), (120, 30), (240, 30)]
    let wrongRates = rates.filter { RenderSettings().outputFrameRate(sourceFPS: $0.source) != $0.expected }
    for r in wrongRates {
        print("       \(r.source) fps → \(RenderSettings().outputFrameRate(sourceFPS: r.source)) (expected \(r.expected))")
    }
    check(wrongRates.isEmpty, "output frame rate for 24/25/29.97/30/50/59.94/60/120/240 fps sources")

    let src60 = tmp.appendingPathComponent("harness-src-60.mp4")
    try await synthesizeClip(to: src60, frames: N, fps: 60)
    let out60 = try await TrailRenderEngine().render(sourceURL: src60, settings: RenderSettings())
    let srcSeconds = try await AVURLAsset(url: src60).load(.duration).seconds
    let outSeconds = try await AVURLAsset(url: out60).load(.duration).seconds
    let frames60 = try await readFrames(out60)
    print(String(format: "       60 fps source %.2f s → export %.2f s, %d frames", srcSeconds, outSeconds, frames60.count))
    // The export drops the 5 black fade-in frames (~0.08 s at 60 fps), so allow a little slack.
    check(abs(outSeconds - srcSeconds) < 0.15, "60 fps source exports in real time (was ~2× long)")
    check(abs(frames60.count - ((N - fadeFrames + 1) / 2 + 1)) <= 2, "60 fps source decimated to ~every 2nd frame")

    // ---- Test 6: storage precision ----
    print("\n[6] Storage precision — half-float age maps, sRGB-encoded image buffers")
    let linear = ctx.workingColorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    // A 10 s fade decayed per frame for 20 s at 30 fps: closed form 0.05² = 0.0025.
    var fadeSettings = RenderSettings()
    fadeSettings.fadeSeconds = 10
    let perFrame = fadeSettings.ageDecay(perFrameAt: 30)
    let expectedAge = fadeSettings.fadeAge(afterSeconds: 20)
    let halfAge = decayedAge(PixelBufferFlattener.scalar(size: ageRect.size), steps: 600, decay: perFrame)
    let legacyAge = decayedAge(PixelBufferFlattener(size: ageRect.size, colorSpace: linear), steps: 600, decay: perFrame)
    print(String(format: "       10 s fade after 20 s: half-float %.4f · closed form %.4f · old 8-bit linear %.4f",
                 halfAge, expectedAge, legacyAge))
    check(abs(halfAge - expectedAge) < 0.002, "per-frame decay in half-float matches the preview's closed form")

    let darkLevels = shadowLevels(PixelBufferFlattener.image(size: rampRect.size))
    let legacyLevels = shadowLevels(PixelBufferFlattener(size: rampRect.size, colorSpace: linear))
    print("       distinct levels for sRGB codes 0…50: image buffer \(darkLevels) · old 8-bit linear \(legacyLevels)")
    check(darkLevels >= 49, "sRGB image buffers keep shadow levels (old linear storage: ~9 of 51)")

    // ---- Test 7: preview covers the whole clip ----
    // 150 frames (5 s): between 96 and 191 frames the old round-down stride (1) stopped the preview
    // at its 96th layer, ~2/3 along the path. A 12 px square moving ~1.7 px/frame clears its own
    // length within K frames, so the temporal mask sees it whole.
    print("\n[7] Preview coverage — 150-frame clip, preview vs export at the end of the path")
    let srcLong = tmp.appendingPathComponent("harness-src-long.mp4")
    try await synthesizeClip(to: srcLong, frames: 150, fps: 30, side: 12)
    let probe = (x: W - 30, y: H / 2)   // on the path's last third; the old preview never got there
    let (pbr, pbg, pbb) = (Int(bgR * 255), Int(bgG * 255), Int(bgB * 255))
    let longOut = try await TrailRenderEngine().render(sourceURL: srcLong, settings: RenderSettings())
    if let exportLast = try await readFrames(longOut).last {
        let (r, g, b) = pixel(toRGBA(exportLast), probe.x, probe.y)
        print("       export final frame at (\(probe.x),\(probe.y)) = (\(r),\(g),\(b))")
        check(r + g + b > pbr + pbg + pbb + 150, "export trail reaches the end of the path")
    } else {
        check(false, "long-clip export has frames")
    }
    let preview = TrailPreviewRenderer()
    await preview.prepare(sourceURL: srcLong, settings: RenderSettings(), cacheDirectory: nil)
    var previewReady = false
    for _ in 0..<300 {    // recompose publishes on the main actor; give it up to ~3 s
        previewReady = await MainActor.run { preview.previewImage != nil }
        if previewReady { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if previewReady, let previewCG = preview.previewImage {
        let buf = render(CIImage(cgImage: previewCG), previewCG.width, previewCG.height)
        let sx = probe.x * previewCG.width / W, sy = probe.y * previewCG.height / H
        let i = (sy * previewCG.width + sx) * 4
        let (r, g, b) = (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        print("       preview at (\(sx),\(sy)) of \(previewCG.width)x\(previewCG.height) = (\(r),\(g),\(b))")
        check(r + g + b > pbr + pbg + pbb + 150, "preview trail reaches the end of the path, like the export")
    } else {
        check(false, "preview produced an image")
    }

    print("\n\(failures == 0 ? "✅ ALL CHECKS PASSED" : "❌ \(failures) CHECK(S) FAILED")")
}

// MARK: - Precision helpers

let ageRect = CGRect(x: 0, y: 0, width: 16, height: 16)

/// Decays a white age map `steps` times by `decay`, re-flattening through `flattener` each step (the
/// engine's per-frame fade loop), and returns the final value read back in linear float.
func decayedAge(_ flattener: PixelBufferFlattener, steps: Int, decay: Double) -> Double {
    var age = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: ageRect)
    let d = CGFloat(decay)
    for _ in 0..<steps {
        autoreleasepool {
            let scaled = age.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: d, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: d, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: d, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            age = flattener.flatten(scaled, rect: ageRect, context: ctx)
        }
    }
    var px = [Float](repeating: 0, count: 4)
    let linear = ctx.workingColorSpace ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    px.withUnsafeMutableBytes { p in
        ctx.render(age, toBitmap: p.baseAddress!, rowBytes: 16,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
    }
    return Double(px[0])
}

let rampRect = CGRect(x: 0, y: 0, width: 51, height: 1)

/// Flattens a ramp of sRGB codes 0…50 through `flattener` and counts the distinct codes that survive.
func shadowLevels(_ flattener: PixelBufferFlattener) -> Int {
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    var bytes: [UInt8] = []
    for code in 0...50 { bytes += [UInt8(code), UInt8(code), UInt8(code), 255] }
    let ramp = CIImage(bitmapData: Data(bytes), bytesPerRow: 51 * 4, size: rampRect.size,
                       format: .RGBA8, colorSpace: srgb)
    let flat = flattener.flatten(ramp, rect: rampRect, context: ctx)
    var out = [UInt8](repeating: 0, count: 51 * 4)
    out.withUnsafeMutableBytes { p in
        ctx.render(flat, toBitmap: p.baseAddress!, rowBytes: 51 * 4, bounds: rampRect,
                   format: .RGBA8, colorSpace: srgb)
    }
    return Set(stride(from: 0, to: out.count, by: 4).map { out[$0] }).count
}

// The preview test hops to the main actor (`TrailPreviewRenderer` publishes there), so keep the
// main queue serviced — blocking it on a semaphore, as this harness used to, would deadlock.
Task {
    do { try await run() }
    catch { print("❌ harness error: \(error)"); failures += 1 }
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
