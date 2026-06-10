import SwiftUI
import AVFoundation

/// Edit-time ignore-region editor (spec §9.3). Shows a still from the source clip and lets the
/// user tap-drag rectangles over areas to exclude from motion detection (waving trees, water,
/// shadows). Regions are stored normalized (0…1, top-left origin) in `regions`.
struct MaskEditorView: View {
    let sourceURL: URL
    @Binding var regions: [CGRect]
    @Environment(\.dismiss) private var dismiss

    @State private var still: CGImage?
    @State private var imageAspect: CGFloat = 9.0 / 16.0
    @State private var draft: CGRect?   // in container coordinates, while dragging

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

                    // Draft region being drawn.
                    if let draft {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 2))
                            .frame(width: draft.width, height: draft.height)
                            .position(x: draft.midX, y: draft.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            draft = rect(from: value.startLocation, to: value.location, clampedTo: frame)
                        }
                        .onEnded { value in
                            let r = rect(from: value.startLocation, to: value.location, clampedTo: frame)
                            if r.width > 6, r.height > 6 {
                                regions.append(normalize(r, in: frame))
                            }
                            draft = nil
                        }
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Ignore regions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { regions.removeAll() }
                        .disabled(regions.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Drag to exclude areas (waving trees, water, shadows). Tap a box to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial)
            }
            .task { await loadStill() }
        }
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
