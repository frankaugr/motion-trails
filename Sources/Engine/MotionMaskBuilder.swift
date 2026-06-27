import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds a soft motion mask for one frame (spec §11.4). The returned image carries the mask in its
/// **alpha** channel — alpha 1 where the subject moved, 0 where the scene is static — which is what
/// `CIBlendWithMask` consumes during compositing.
///
/// Detection is **temporal**: a frame is compared to its neighbours K frames *before and after*
/// (`makeMask(current:earlier:later:)`), not to the long-term background plate. A slow drift (clouds,
/// a swaying tree) barely changes over ±K, so it cancels; a fast subject (birds) displaces fully, so
/// it survives. The symmetric `min` of the backward and forward differences localizes the subject at
/// its position at time *t* (it removes the trailing "ghost" each one-sided difference leaves). A
/// legacy single-reference overload (`makeMask(current:background:)`) is kept for tooling.
struct MotionMaskBuilder {

    /// Temporal motion mask: subject = what differs from BOTH the `earlier` (t−K) and `later` (t+K)
    /// frames. Pass `nil` for a neighbour that doesn't exist; detection then falls back to the
    /// single available side. **Production callers pass the pair both-or-nothing**: a one-sided
    /// difference also lights up the subject's position in the *reference* frame (the trailing
    /// "ghost" the symmetric min removes), which stamped false marks near clip ends — the engine
    /// and preview shrink the horizon toward the centre instead and pass `nil` for both sides when
    /// one can't be resolved.
    ///
    /// - Parameter radiusScale: multiplies the morphology radius so the mask can be built at a
    ///   downscaled working resolution (the engine's mask working space and the live preview's
    ///   proxy) while keeping the same effective feature size relative to the frame. Leave at 1
    ///   when masking at full resolution.
    func makeMask(current: CIImage, earlier: CIImage?, later: CIImage?,
                  settings: RenderSettings, radiusScale: CGFloat = 1) -> CIImage {
        let mode = settings.contrastMode
        let back = earlier.flatMap { motionSignal(current: current, reference: $0, mode: mode) }
        let fwd  = later.flatMap { motionSignal(current: current, reference: $0, mode: mode) }

        let mag: CIImage?
        switch (back, fwd) {
        case let (b?, f?): mag = darken(b, f)   // per-pixel min → subject localized at time t
        case let (b?, nil): mag = b
        case let (nil, f?): mag = f
        case (nil, nil): mag = nil               // no temporal reference → no motion this frame
        }
        return finish(mag ?? CIImage(color: .black).cropped(to: current.extent),
                      extent: current.extent, settings: settings, radiusScale: radiusScale)
    }

    /// Legacy single-reference mask (current vs. a static `background`). Retained for the headless
    /// harness and any non-temporal tooling; the render/preview paths use the temporal overload.
    func makeMask(current: CIImage, background: CIImage, settings: RenderSettings,
                  radiusScale: CGFloat = 1) -> CIImage {
        let mag = motionSignal(current: current, reference: background, mode: settings.contrastMode) ?? current
        return finish(mag, extent: current.extent, settings: settings, radiusScale: radiusScale)
    }

    /// Shared mask tail: threshold → opening (despeckle) → closing (fill holes) → feather → alpha.
    private func finish(_ signal: CIImage, extent: CGRect, settings: RenderSettings,
                        radiusScale: CGFloat) -> CIImage {
        // Threshold to a hard mask; the contrast mode's cutoff drives it.
        let threshold = CIFilter.colorThreshold()
        threshold.inputImage = signal
        threshold.threshold = Float(settings.differenceThreshold)

        // Opening (erode → dilate) removes speckle and sub-minimum regions.
        let radius = max(0.5, Float(settings.morphologyRadius) * Float(radiusScale))
        let opened = dilate(erode(threshold.outputImage, radius: radius), radius: radius)

        // Closing (dilate → erode) fills small holes inside the subject.
        let closeRadius = max(1, radius * 0.75)
        let closed = erode(dilate(opened, radius: closeRadius), radius: closeRadius)

        // Light feather so composited subject edges aren't aliased (edge preservation, §11.4).
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = closed
        blur.radius = 1.0

        // Move the grayscale mask into the alpha channel for CIBlendWithMask.
        let maskToAlpha = CIFilter.maskToAlpha()
        maskToAlpha.inputImage = blur.outputImage

        let result = maskToAlpha.outputImage ?? signal
        // Morphology and blur enlarge the extent; crop back to the frame.
        return result.cropped(to: extent)
    }

    /// Builds the scalar motion magnitude between `current` and a `reference` image for the chosen
    /// `ContrastMode`. Each mode keys on a different kind of contrast, so change of the *other* kinds
    /// stays below the threshold:
    /// - `.any`: per-channel `|current − reference|` collapsed to its max channel — any change.
    /// - `.silhouette`: `max(0, luma(ref) − luma(cur))` — current went *darker* (dark on light).
    /// - `.highlight`: `max(0, luma(cur) − luma(ref))` — current went *brighter* (light on dark).
    /// - `.colour`: `max(0, colourMag − |Δluma|)` — colour change beyond what a brightness change
    ///   explains (different hue at similar lightness).
    ///
    /// `max(0, x − y)` is built as `|x − min(x, y)|`, since `min(x, y) ≤ x` makes the difference
    /// exactly the positive part. For temporal detection `reference` is a neighbouring frame; for the
    /// legacy path it is the static background plate.
    private func motionSignal(current: CIImage, reference: CIImage,
                              mode: RenderSettings.ContrastMode) -> CIImage? {
        switch mode {
        case .any:
            return maximumComponent(difference(current, reference))
        case .silhouette:
            // Lift shadows (power < 1) so a dark subject on a *dark* background still clears the
            // absolute threshold.
            let lc = tonemap(current, power: 0.5), lb = tonemap(reference, power: 0.5)
            return difference(lb, darken(lc, lb))            // max(0, Lref − Lcur)
        case .highlight:
            // Expand highlights (power > 1) for the mirror case: a bright subject on a *bright* bg.
            let lc = tonemap(current, power: 2.0), lb = tonemap(reference, power: 2.0)
            return difference(lc, darken(lc, lb))            // max(0, Lcur − Lref)
        case .colour:
            let colourMag = maximumComponent(difference(current, reference))
            let lumaDelta = difference(luminance(current), luminance(reference))
            return difference(colourMag, darken(colourMag, lumaDelta))   // max(0, colourMag − |Δluma|)
        }
    }

    /// Opaque grayscale luminance (Rec. 601) so downstream blends operate on brightness alone.
    private func luminance(_ image: CIImage) -> CIImage {
        let m = CIFilter.colorMatrix()
        m.inputImage = image
        let luma = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        m.rVector = luma
        m.gVector = luma
        m.bVector = luma
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return m.outputImage ?? image
    }

    /// Luminance run through a tone curve (`luma ^ power`) before differencing. The luminance modes
    /// threshold an *absolute* difference, which collapses at one end of the range: a black bird on a
    /// dusky sky is high-contrast but only a small absolute drop, so it falls below the cutoff.
    /// `power < 1` lifts shadows (for `.silhouette`, dark-on-dark); `power > 1` expands highlights
    /// (for `.highlight`, bright-on-bright), so the same threshold works across brightness levels.
    private func tonemap(_ image: CIImage, power: Double) -> CIImage {
        let luma = luminance(image)
        let g = CIFilter.gammaAdjust()
        g.inputImage = luma
        g.power = Float(power)
        return g.outputImage ?? luma
    }

    /// Per-channel `|a − b|`.
    private func difference(_ a: CIImage?, _ b: CIImage?) -> CIImage? {
        guard let a else { return b }
        let d = CIFilter.differenceBlendMode()
        d.inputImage = a
        d.backgroundImage = b
        return d.outputImage
    }

    /// Per-channel `min(a, b)`.
    private func darken(_ a: CIImage?, _ b: CIImage?) -> CIImage? {
        let f = CIFilter.darkenBlendMode()
        f.inputImage = a
        f.backgroundImage = b
        return f.outputImage
    }

    /// Collapses RGB to a single magnitude (the max channel).
    private func maximumComponent(_ image: CIImage?) -> CIImage? {
        let f = CIFilter.maximumComponent()
        f.inputImage = image
        return f.outputImage
    }

    /// Shrinks bright regions (`CIMorphologyMinimum`).
    private func erode(_ image: CIImage?, radius: Float) -> CIImage? {
        guard let image else { return nil }
        let f = CIFilter.morphologyMinimum()
        f.inputImage = image
        f.radius = radius
        return f.outputImage
    }

    /// Grows bright regions (`CIMorphologyMaximum`).
    private func dilate(_ image: CIImage?, radius: Float) -> CIImage? {
        guard let image else { return nil }
        let f = CIFilter.morphologyMaximum()
        f.inputImage = image
        f.radius = radius
        return f.outputImage
    }
}
