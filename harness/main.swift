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
//
// It synthesizes a clip (uniform colored background + a white square sweeping the mid band, with a
// black fade-in), runs BackgroundEstimator and TrailRenderEngine, inspects pixels, dumps the first
// and last output frames as PNGs, and prints timings. Run with:
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

func drawFrame(_ i: Int) -> CVPixelBuffer {
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
        let t = Double(i - fadeFrames) / Double(N - fadeFrames - 1)
        let x = Int(t * Double(W - square))
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: x, y: (H - square) / 2, width: square, height: square))
    }
    return pb
}

func synthesizeClip() async throws {
    try? FileManager.default.removeItem(at: srcURL)
    let writer = try AVAssetWriter(outputURL: srcURL, fileType: .mp4)
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
    for i in 0..<N {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        adaptor.append(drawFrame(i), withPresentationTime: CMTime(value: Int64(i), timescale: 30))
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

    // Trail persistence: a pixel in the square's early path (left side, mid band) should be bright
    // in the last frame — the silhouette was stamped into the trail and never overwritten.
    let (tr, tg, tb) = pixel(lastBuf, 20, H / 2)
    let (br, bg2, bb) = pixel(lastBuf, 20, staticY)   // background at the same column
    print("       trail pixel (20,\(H/2)) = (\(tr),\(tg),\(tb)) vs background = (\(br),\(bg2),\(bb))")
    check(tr + tg + tb > (br + bg2 + bb) + 80, "trail silhouette persisted (brighter than background)")

    // ---- Test 3: render with fade on (exercises per-frame ageMap flatten path) ----
    print("\n[3] Render (fade enabled) — per-frame age-map flatten")
    settings.fadeAmount = 0.5
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

    print("\n\(failures == 0 ? "✅ ALL CHECKS PASSED" : "❌ \(failures) CHECK(S) FAILED")")
}

let sema = DispatchSemaphore(value: 0)
Task {
    do { try await run() }
    catch { print("❌ harness error: \(error)"); failures += 1 }
    sema.signal()
}
sema.wait()
exit(failures == 0 ? 0 : 1)
