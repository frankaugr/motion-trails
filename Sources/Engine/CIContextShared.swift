import CoreImage
import Metal

/// A single Metal-backed `CIContext` shared across the whole render pipeline.
///
/// Creating a `CIContext` is expensive and each one holds its own GPU caches, so the
/// engine reuses one instance for diff/threshold/morphology/composite and final encode.
enum SharedRender {
    static let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "MotionTrails"
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        // Fallback for environments without a Metal device (shouldn't happen on device/sim).
        return CIContext(options: options)
    }()
}
