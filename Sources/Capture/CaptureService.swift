import AVFoundation
import Observation

/// Camera capture (spec §7.1, §7.2, §10.2). Configures a 1080p high-frame-rate session, locks
/// focus/exposure/white balance after they settle, records the source clip to a temp file with a
/// hard duration cap, and surfaces a low-light warning.
///
/// Frame access for a live trail preview is intentionally omitted (MVP uses the post-capture
/// render, spec §21.4); a plain `AVCaptureMovieFileOutput` keeps the source clean and reliable.
@Observable
final class CaptureService: NSObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.frank.motiontrails.capture")
    private var device: AVCaptureDevice?
    private var finishContinuation: CheckedContinuation<URL, Error>?

    private(set) var isReady = false
    private(set) var isRecording = false
    private(set) var permissionDenied = false
    private(set) var lightingWarning: String?

    /// Hard recording cap (seconds). Driven by the free/premium entitlement (spec §7.1).
    var maxRecordingDuration: Double = 5 {
        didSet { sessionQueue.async { self.applyMaxDuration() } }
    }

    /// Premium + capable devices capture at 4K; otherwise 1080p (spec §8, §16). Set before `configure`.
    var prefersHighestResolution = false

    // MARK: - Setup

    func configure() async {
        guard await requestPermission() else {
            await MainActor.run { self.permissionDenied = true }
            return
        }
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                self.configureSession()
                continuation.resume()
            }
        }
        await MainActor.run { self.isReady = true }
    }

    private func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else { return }
        device = camera

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
        } catch {
            return
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }

        selectBestFormat(for: camera)
        applyMaxDuration()
    }

    /// Picks the 1080p format with the highest supported frame rate and locks the active frame
    /// rate to it (capability-gated; spec §5, §23 60fps target).
    private func selectBestFormat(for device: AVCaptureDevice) {
        // Premium + capable: prefer 2160p; otherwise (or as fallback) the best 1080p.
        let targetHeight: Int32 = prefersHighestResolution ? 2160 : 1080
        var best: AVCaptureDevice.Format?
        var bestFPS = 0.0
        for height in [targetHeight, 1080] {
            for format in device.formats {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.height == height else { continue }
                for range in format.videoSupportedFrameRateRanges where range.maxFrameRate > bestFPS {
                    bestFPS = range.maxFrameRate
                    best = format
                }
            }
            if best != nil { break }   // found formats at the preferred height
        }
        guard let chosen = best, bestFPS > 0 else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            let targetFPS = min(60.0, bestFPS)   // 60fps practical default (spec §23)
            let duration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // Keep defaults if the format can't be applied.
        }
    }

    private func applyMaxDuration() {
        movieOutput.maxRecordedDuration = CMTime(seconds: maxRecordingDuration, preferredTimescale: 600)
    }

    // MARK: - Running / locking

    func startRunning() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
    }

    func stopRunning() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Locks focus/exposure/white balance once they've had a moment to settle, and raises a
    /// low-light warning (spec §7.2, §7.4, §21.1).
    func lockSettings() {
        sessionQueue.asyncAfter(deadline: .now() + 0.8) {
            guard let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
            } catch {}

            let lowLight = device.iso > device.activeFormat.maxISO * 0.6
            DispatchQueue.main.async {
                self.lightingWarning = lowLight
                    ? "Low light — trails may blur or look noisy. Prefer bright, outdoor scenes."
                    : nil
            }
        }
    }

    // MARK: - Recording

    /// Records to a temp file, resolving when the user stops or the duration cap is reached.
    func record() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).mov")
        return try await withCheckedThrowingContinuation { continuation in
            self.finishContinuation = continuation
            self.sessionQueue.async {
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
                DispatchQueue.main.async { self.isRecording = true }
            }
        }
    }

    func stop() {
        sessionQueue.async { if self.movieOutput.isRecording { self.movieOutput.stopRecording() } }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }
        let continuation = finishContinuation
        finishContinuation = nil

        if let error = error as NSError? {
            // Hitting the duration cap still produces a valid file.
            let finishedOK = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if finishedOK {
                continuation?.resume(returning: outputFileURL)
            } else {
                continuation?.resume(throwing: error)
            }
        } else {
            continuation?.resume(returning: outputFileURL)
        }
    }
}
