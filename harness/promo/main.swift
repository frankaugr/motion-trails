import AVFoundation
import CoreImage
import CoreGraphics
import Foundation

// Promo render harness — drives the real TrailRenderEngine on an arbitrary clip so we can produce
// marketing/demo output that is byte-for-byte the app's render (not an ffmpeg approximation).
//
// Lives in its own directory (named main.swift so top-level code is allowed) and is compiled WITHOUT
// harness/main.swift (which also has top-level code):
//
//   swiftc -swift-version 5 Sources/Engine/*.swift harness/promo/main.swift -o /tmp/promorender
//   /tmp/promorender <input.mp4> <output.mp4> [contrast=silhouette] [horizon=0.25] [freq=0.8] \
//       [fade=0] [bg=frozen] [mode=trail] [maxdim=1920]
//
// contrast: any|silhouette|highlight|colour   mode: trail|mask   bg: frozen|live

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: promorender <input> <output> [key=value ...]\n".utf8))
    exit(2)
}
let inURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

// Parse optional key=value overrides so we can tune without recompiling.
var kv: [String: String] = [:]
for a in args.dropFirst(3) {
    let parts = a.split(separator: "=", maxSplits: 1)
    if parts.count == 2 { kv[String(parts[0])] = String(parts[1]) }
}
func str(_ k: String, _ d: String) -> String { kv[k] ?? d }
func dbl(_ k: String, _ d: Double) -> Double { kv[k].flatMap(Double.init) ?? d }

var settings = RenderSettings()
settings.contrastMode = RenderSettings.ContrastMode(rawValue: str("contrast", "silhouette")) ?? .silhouette
settings.motionHorizonSeconds = dbl("horizon", 0.25)
settings.trailFrequency = dbl("freq", 0.8)
settings.fadeSeconds = dbl("fade", 0)
settings.backgroundMode = RenderSettings.BackgroundMode(rawValue: str("bg", "static")) ?? .frozen
settings.colorStyle = .natural
settings.handheldAmount = 0

let outputMode: TrailRenderEngine.Output = (str("mode", "trail") == "mask") ? .mask : .trail
let maxDim = CGFloat(dbl("maxdim", 1920))

func run() async throws {
    let t0 = Date()
    print("Rendering \(inURL.lastPathComponent) -> \(outURL.lastPathComponent)")
    print("  contrast=\(settings.contrastMode.rawValue) horizon=\(settings.motionHorizonSeconds) " +
          "freq=\(settings.trailFrequency) fade=\(settings.fadeSeconds) " +
          "bg=\(settings.backgroundMode.rawValue) mode=\(str("mode", "trail")) maxdim=\(Int(maxDim))")

    var lastPct = -1
    let produced = try await TrailRenderEngine().render(
        sourceURL: inURL,
        settings: settings,
        output: outputMode,
        maxOutputDimension: maxDim,
        progress: { p in
            let pct = Int(p * 100)
            if pct >= lastPct + 5 { lastPct = pct; print("  \(pct)%") }
        },
        stage: { stage in print("  stage: \(stage)") }
    )

    try? FileManager.default.removeItem(at: outURL)
    try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: produced, to: outURL)
    let secs = Date().timeIntervalSince(t0)
    print(String(format: "Done in %.1fs -> %@", secs, outURL.path))
}

let sema = DispatchSemaphore(value: 0)
var failed = false
Task {
    do { try await run() }
    catch { FileHandle.standardError.write(Data("render error: \(error)\n".utf8)); failed = true }
    sema.signal()
}
sema.wait()
exit(failed ? 1 : 0)
