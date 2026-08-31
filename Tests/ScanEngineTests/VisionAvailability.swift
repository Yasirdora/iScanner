import Testing
import Foundation
import CoreGraphics
import ScanCapture
import ScanRecognize

// Vision's recogniser and page detectors fail on GitHub's macOS runners: every
// request throws `unknownError` there (first seen in CI run 39130408030, with
// the same Xcode 27.0 build that passes on an Apple silicon Mac). The most
// likely reason is that a virtual Mac does not expose the hardware Vision's
// models run on.
//
// So on CI only, tests that need Vision first check that it works, and are
// skipped with that reason when it does not. On any other machine nothing is
// skipped: if Vision breaks on a real Mac, these tests still fail.

enum VisionAvailability {
    /// GitHub Actions, like most CI services, sets `CI=true`.
    static let isCI = ProcessInfo.processInfo.environment["CI"] == "true"

    /// Probed once per test run and shared by every test that asks.
    private static let probe = Task { await probeVision() }

    static func usable() async -> Bool { await probe.value }

    /// Runs the two kinds of Vision request the engine uses — document
    /// recognition and page detection — on a small blank page.
    private static func probeVision() async -> Bool {
        guard let context = CGContext(
            data: nil, width: 64, height: 64,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let page = context.makeImage() else { return false }
        do {
            _ = try await DocumentRecognizer().recognize(page)
            _ = try await DocumentCandidateSelector().best(in: page)
            return true
        } catch {
            return false
        }
    }
}

extension Trait where Self == ConditionTrait {
    /// For tests that call Vision. Skips only on CI, and only when Vision
    /// does not work there.
    static var needsVision: Self {
        .enabled("Vision does not run on this CI machine (a virtual Mac); these tests run on a real Mac") {
            guard VisionAvailability.isCI else { return true }
            return await VisionAvailability.usable()
        }
    }
}
