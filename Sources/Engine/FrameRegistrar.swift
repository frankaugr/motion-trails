import CoreImage
import Vision

/// Compensates for minor tripod drift by translating each frame to align with the static
/// background before motion detection (spec §11.3, initial translational implementation).
///
/// Vision treats the *targeted* image as the "floating" image and the request handler's image
/// as the unchanging "reference"; the resulting `alignmentTransform` morphs the floating image
/// onto the reference. So the current frame is the target and the background is the reference,
/// and the transform is applied to the frame.
final class FrameRegistrar {
    private let reference: CIImage
    /// Maximum plausible drift, in pixels. Larger estimated shifts are rejected.
    private let maxShift: CGFloat

    /// - Parameter maxShiftFraction: drift cap as a fraction of the larger image dimension.
    init(reference: CIImage, maxShiftFraction: CGFloat = 0.02) {
        self.reference = reference
        self.maxShift = max(reference.extent.width, reference.extent.height) * maxShiftFraction
    }

    /// Returns `frame` translated into alignment with the background. The result is clamped to
    /// its extent so shifted-in borders extend the edge pixels instead of going transparent
    /// (transparent borders would otherwise read as motion). Falls back to the original frame
    /// if registration fails or returns an implausibly large shift.
    ///
    /// The shift cap matters: on low-feature scenes Vision can lock onto the moving subjects and
    /// translate by *their* motion (tens of pixels, erratic), which misaligns the static
    /// background and corrupts the whole frame. Genuine tripod drift is small, so we reject big
    /// shifts and leave the frame untouched.
    func align(_ frame: CIImage) -> CIImage {
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: frame)
        let handler = VNImageRequestHandler(ciImage: reference)
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return frame }
            let transform = observation.alignmentTransform
            guard abs(transform.tx) <= maxShift, abs(transform.ty) <= maxShift else { return frame }
            return frame.transformed(by: transform).clampedToExtent()
        } catch {
            return frame
        }
    }
}
