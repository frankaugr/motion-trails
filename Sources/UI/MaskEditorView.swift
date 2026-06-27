import SwiftUI
import AVFoundation

/// Edit-time ignore-region editor (spec §9.3). Shows a still from the source clip and lets the
/// user draw rectangles (box tool) or freehand strokes (brush tool, with a size control) over
/// areas to exclude from motion detection (waving trees, water, shadows). Geometry is stored
/// normalized (0…1, top-left origin) in `regions`/`strokes`; stroke radii are normalized to the
/// image width (`RenderSettings.IgnoreStroke`).
struct MaskEditorView: View {
    let sourceURL: URL
    @Binding var regions: [CGRect]
    @Binding var strokes: [RenderSettings.IgnoreStroke]
    @Environment(\.dismiss) private var dismiss

    private enum Tool: String, CaseIterable, Identifiable {
        case box, brush
        var id: String { rawValue }
        var label: String { self == .box ? "Box" : "Brush" }
        var icon: String { self == .box ? "rectangle.dashed" : "paintbrush.pointed" }
    }

    @State private var still: CGImage?
    @State private var imageAspect: CGFloat = 9.0 / 16.0
    @State private var tool: Tool = .box
    @State private var brushRadius: Double = 0.04        // normalized to image width
    @State private var sizingBrush = false               // slider in flight → show size ghost
    @State private var draftRect: CGRect?                // container coords, while dragging (box)
    @State private var draftPoints: [CGPoint] = []       // container coords, while dragging (brush)

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let frame = fittedRect(containerSize: geo.size)
                ZStack {
                    Color.black
                    stillImage
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    // Committed regions.
                    ForEach(Array(regions.enumerated()), id: \.offset) { index, region in
                        let r = denormalize(region, in: frame)
                        Rectangle()
                            .fill(.red.opacity(0.30))
                            .overlay(Rectangle().stroke(.red, lineWidth: 2))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture { regions.remove(at: index) }
                    }

                    // Committed strokes — tap to remove, like boxes.
                    ForEach(Array(strokes.enumerated()), id: \.offset) { index, stroke in
                        let points = stroke.points.map { denormalizePoint($0, in: frame) }
                        let radius = stroke.radius * frame.width
                        strokeBlob(points, radius: radius, color: .red.opacity(0.35))
                            .contentShape(brushHitArea(points, radius: radius))
                            .onTapGesture { strokes.remove(at: index) }
                    }

                    // Draft shapes being drawn.
                    if let draftRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: draftRect.width, height: draftRect.height)
                            .position(x: draftRect.midX, y: draftRect.midY)
                    }
                    if !draftPoints.isEmpty {
                        strokeBlob(draftPoints, radius: brushRadius * frame.width,
                                   color: Color.accentColor.opacity(0.35))
                    }

                    // Ghost circle while the size slider is in flight, so the brush size is legible.
                    if sizingBrush {
                        let d = brushRadius * frame.width * 2
                        Circle()
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                            .frame(width: d, height: d)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(drawGesture(in: frame))
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Ignore regions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        regions.removeAll()
                        strokes.removeAll()
                    }
                    .disabled(regions.isEmpty && strokes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { controls }
            .task { await loadStill() }
        }
        // A downward brush stroke must not arm the sheet's drag-to-dismiss (it interrupts the
        // drawing gesture mid-stroke, leaving fragments). Exit is the Done button.
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private var stillImage: some View {
        if let still {
            Image(decorative: still, scale: 1, orientation: .up)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            ProgressView().tint(.white)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Tool", selection: $tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.label, systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented)
            if tool == .brush {
                HStack(spacing: 12) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                    Slider(value: $brushRadius, in: 0.015...0.12) { sizingBrush = $0 }
                        .accessibilityLabel("Brush size")
                    Image(systemName: "circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            Text(tool == .box
                 ? "Drag to box out areas (waving trees, water, shadows). Tap a shape to remove it."
                 : "Paint over areas to exclude. Tap a shape to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    // MARK: - Drawing

    private func drawGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                switch tool {
                case .box:
                    draftRect = rect(from: value.startLocation, to: value.location, clampedTo: frame)
                case .brush:
                    let p = clamp(value.location, to: frame)
                    if draftPoints.isEmpty {
                        draftPoints = [clamp(value.startLocation, to: frame), p]
                    } else if let last = draftPoints.last, hypot(p.x - last.x, p.y - last.y) >= 3 {
                        draftPoints.append(p)
                    }
                }
            }
            .onEnded { value in
                switch tool {
                case .box:
                    let r = rect(from: value.startLocation, to: value.location, clampedTo: frame)
                    if r.width > 6, r.height > 6 {
                        regions.append(normalize(r, in: frame))
                    }
                    draftRect = nil
                case .brush:
                    if draftPoints.count >= 2 {
                        strokes.append(RenderSettings.IgnoreStroke(
                            points: draftPoints.map { normalizePoint($0, in: frame) },
                            radius: brushRadius))
                    }
                    draftPoints = []
                }
            }
    }

    /// Renders a brush stroke (container coords) as one continuous translucent blob: a single-pass
    /// stroke of the polyline, or a disc for a single point. Don't render by filling
    /// `strokedPath`'s outline — that path carries every internal cap/join contour, which shows up
    /// as overlapping squares and lines along the stroke instead of a clean silhouette.
    @ViewBuilder
    private func strokeBlob(_ points: [CGPoint], radius: CGFloat, color: Color) -> some View {
        if points.count <= 1, let p = points.first {
            Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                   width: radius * 2, height: radius * 2))
                .fill(color)
        } else {
            polyline(points)
                .stroke(color, style: StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        return path
    }

    /// Tap-target shape matching a stroke's painted area (used only for `contentShape`, never
    /// rendered — its internal contours don't matter for hit testing).
    private func brushHitArea(_ points: [CGPoint], radius: CGFloat) -> Path {
        guard let first = points.first else { return Path() }
        if points.count == 1 {
            return Path(ellipseIn: CGRect(x: first.x - radius, y: first.y - radius,
                                          width: radius * 2, height: radius * 2))
        }
        return polyline(points)
            .strokedPath(StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round))
    }

    // MARK: - Geometry

    private func fittedRect(containerSize: CGSize) -> CGRect {
        let containerAspect = containerSize.width / containerSize.height
        var w = containerSize.width
        var h = containerSize.height
        if imageAspect > containerAspect {
            h = w / imageAspect
        } else {
            w = h * imageAspect
        }
        return CGRect(x: (containerSize.width - w) / 2, y: (containerSize.height - h) / 2, width: w, height: h)
    }

    private func rect(from a: CGPoint, to b: CGPoint, clampedTo frame: CGRect) -> CGRect {
        let minX = max(frame.minX, min(a.x, b.x))
        let maxX = min(frame.maxX, max(a.x, b.x))
        let minY = max(frame.minY, min(a.y, b.y))
        let maxY = min(frame.maxY, max(a.y, b.y))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func clamp(_ p: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, frame.minX), frame.maxX),
                y: min(max(p.y, frame.minY), frame.maxY))
    }

    private func normalize(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: (r.minX - frame.minX) / frame.width,
               y: (r.minY - frame.minY) / frame.height,
               width: r.width / frame.width,
               height: r.height / frame.height)
    }

    private func denormalize(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width,
               y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width,
               height: r.height * frame.height)
    }

    private func normalizePoint(_ p: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: (p.x - frame.minX) / frame.width,
                y: (p.y - frame.minY) / frame.height)
    }

    private func denormalizePoint(_ p: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + p.x * frame.width,
                y: frame.minY + p.y * frame.height)
    }

    private func loadStill() async {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let t = CMTime(seconds: duration > 0 ? min(duration * 0.5, duration - 0.1) : 0, preferredTimescale: 600)
        if let result = try? await generator.image(at: t) {
            still = result.image
            imageAspect = CGFloat(result.image.width) / CGFloat(result.image.height)
        }
    }
}
