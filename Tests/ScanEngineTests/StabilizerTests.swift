import Testing
import Foundation
import CoreGraphics
import ScanCapture

/// A page filling most of the frame, optionally nudged and skewed.
func page(
    offset: CGFloat = 0,
    inset: CGFloat = 0.1,
    skewTop: CGFloat = 0
) -> DocumentQuad {
    DocumentQuad(
        topLeft: CGPoint(x: inset + offset + skewTop, y: 1 - inset),
        topRight: CGPoint(x: 1 - inset + offset - skewTop, y: 1 - inset),
        bottomRight: CGPoint(x: 1 - inset + offset, y: inset),
        bottomLeft: CGPoint(x: inset + offset, y: inset)
    )
}

/// Runs frames at 30 fps and returns how many captures fired.
func captures(
    _ stabilizer: inout CaptureStabilizer,
    frames: [DocumentQuad?],
    startingAt start: Double = 0,
    confidence: Float = 0.9
) -> Int {
    var count = 0
    for (index, quad) in frames.enumerated() {
        let decision = stabilizer.update(
            quad: quad,
            confidence: quad == nil ? 0 : confidence,
            now: start + Double(index) / 30
        )
        if decision.shouldCapture { count += 1 }
    }
    return count
}

@Test("A page held steady is captured exactly once, however long it is held")
func steadyPageCapturesOnce() {
    // The reported failure: one sheet, two shots. Four seconds of a motionless
    // page must produce a single capture, not one per settle window.
    var stabilizer = CaptureStabilizer()
    let held = Array(repeating: Optional(page()), count: 120)
    #expect(captures(&stabilizer, frames: held) == 1)
}

@Test("A page still moving is never captured")
func movingPageIsNotCaptured() {
    // The other half of the report: a distorted frame taken part way through
    // the movement. Continuous drift must never satisfy the settle rule.
    var stabilizer = CaptureStabilizer()
    let drifting = (0..<120).map { Optional(page(offset: CGFloat($0) * 0.004)) }
    #expect(captures(&stabilizer, frames: drifting) == 0)
}

@Test("Movement then stillness captures once, after the movement stops")
func settlingCapturesOnce() {
    var stabilizer = CaptureStabilizer()
    let moving = (0..<20).map { Optional(page(offset: CGFloat($0) * 0.004)) }
    let settled = Array(repeating: Optional(page(offset: 0.076)), count: 40)
    #expect(captures(&stabilizer, frames: moving + settled) == 1)
}

@Test("Replacing the page with a different one captures again")
func newPageCapturesAgain() {
    var stabilizer = CaptureStabilizer()
    let first = Array(repeating: Optional(page(inset: 0.10)), count: 60)
    // Far enough across the frame to overlap the first sheet very little.
    let second = Array(repeating: Optional(page(offset: 0.55, inset: 0.10)), count: 60)
    #expect(captures(&stabilizer, frames: first + second) == 2)
}

@Test("Lifting the phone away and returning captures the next page")
func pageRemovedThenNewPage() {
    var stabilizer = CaptureStabilizer()
    let first = Array(repeating: Optional(page()), count: 60)
    let empty: [DocumentQuad?] = Array(repeating: nil, count: 15)
    let second = Array(repeating: Optional(page()), count: 60)
    #expect(captures(&stabilizer, frames: first + empty + second) == 2)
}

@Test("A page too small in frame is not captured")
func smallPageIsNotCaptured() {
    var stabilizer = CaptureStabilizer()
    let distant = Array(repeating: Optional(page(inset: 0.40)), count: 90)
    let result = CaptureStabilizer().guidanceOnly(distant.first!!)
    #expect(captures(&stabilizer, frames: distant) == 0)
    #expect(result == .moveCloser)
}

@Test("A steeply angled page is not captured")
func skewedPageIsNotCaptured() {
    var stabilizer = CaptureStabilizer()
    let angled = Array(repeating: Optional(page(skewTop: 0.22)), count: 90)
    #expect(captures(&stabilizer, frames: angled) == 0)
}

@Test("A low-confidence detection is treated as no page at all")
func lowConfidenceIsIgnored() {
    var stabilizer = CaptureStabilizer()
    let frames = Array(repeating: Optional(page()), count: 90)
    #expect(captures(&stabilizer, frames: frames, confidence: 0.2) == 0)
}

@Test("Guidance walks from searching through holding steady to captured")
func guidanceProgresses() {
    var stabilizer = CaptureStabilizer()
    #expect(stabilizer.update(quad: nil, confidence: 0, now: 0).guidance == .searching)

    var sawHoldSteady = false
    var sawCaptured = false
    for frame in 0..<30 {
        let decision = stabilizer.update(quad: page(), confidence: 0.9, now: Double(frame) / 30)
        if case .holdSteady = decision.guidance { sawHoldSteady = true }
        if decision.guidance == .captured { sawCaptured = true }
    }
    #expect(sawHoldSteady)
    #expect(sawCaptured)
}

@Test("A manual shot suppresses an immediate automatic one")
func manualCaptureSuppressesAuto() {
    var stabilizer = CaptureStabilizer()
    stabilizer.noteManualCapture(quad: page(), now: 0)
    let held = Array(repeating: Optional(page()), count: 60)
    #expect(captures(&stabilizer, frames: held, startingAt: 0) == 0)
}

private extension CaptureStabilizer {
    /// Guidance for a single detection, from a fresh stabiliser.
    func guidanceOnly(_ quad: DocumentQuad) -> CaptureGuidance {
        var copy = self
        return copy.update(quad: quad, confidence: 0.9, now: 0).guidance
    }
}

// MARK: - Overlay smoothing

/// Deterministic pseudo-random jitter, so the test measures the filter rather
/// than the luck of a seed.
func jittered(_ quad: DocumentQuad, frame: Int, amplitude: Double) -> DocumentQuad {
    func wobble(_ index: Int) -> CGFloat {
        let phase = Double(frame * 7 + index * 31)
        return CGFloat(sin(phase) * amplitude)
    }
    return DocumentQuad(
        topLeft: CGPoint(x: quad.topLeft.x + wobble(0), y: quad.topLeft.y + wobble(1)),
        topRight: CGPoint(x: quad.topRight.x + wobble(2), y: quad.topRight.y + wobble(3)),
        bottomRight: CGPoint(x: quad.bottomRight.x + wobble(4), y: quad.bottomRight.y + wobble(5)),
        bottomLeft: CGPoint(x: quad.bottomLeft.x + wobble(6), y: quad.bottomLeft.y + wobble(7))
    )
}

/// Mean frame-to-frame corner movement — how much the outline visibly shakes.
func shake(_ quads: [DocumentQuad]) -> Double {
    guard quads.count > 1 else { return 0 }
    let drifts = zip(quads.dropFirst(), quads).map { $0.maximumCornerDrift(from: $1) }
    return drifts.reduce(0, +) / Double(drifts.count)
}

@Test("Smoothing removes detector jitter from a still page")
func smoothingRemovesJitter() {
    // The reported symptom: the outline jumps all over the page. Vision returns
    // a slightly different quad every frame, and drawn raw that shimmers.
    let base = page()
    let noisy = (0..<90).map { jittered(base, frame: $0, amplitude: 0.006) }

    var smoother = QuadSmoother()
    let smoothed = noisy.enumerated().compactMap { index, quad in
        smoother.smooth(quad, now: Double(index) / 30)
    }

    let before = shake(noisy)
    let after = shake(smoothed)
    #expect(before > 0.004, "fixture should be visibly jittery, measured \(before)")
    #expect(after < before / 4, "shake went \(before) -> \(after)")
}

@Test("Smoothing still tracks a page that is genuinely moving")
func smoothingTracksRealMovement() {
    // The failure mode of over-smoothing: an outline that lags behind the page
    // and feels detached from it. After a second of steady movement the filter
    // must have caught up to within a small fraction of the frame.
    var smoother = QuadSmoother()
    var latest: DocumentQuad?
    for frame in 0..<30 {
        latest = smoother.smooth(page(offset: CGFloat(frame) * 0.01), now: Double(frame) / 30)
    }
    let truth = page(offset: 0.29)
    let lag = latest?.maximumCornerDrift(from: truth) ?? 1
    #expect(lag < 0.03, "outline lagged the page by \(lag)")
}

@Test("A single missed detection does not blink the outline away")
func briefDropoutKeepsOutline() {
    var smoother = QuadSmoother()
    for frame in 0..<20 {
        _ = smoother.smooth(page(), now: Double(frame) / 30)
    }
    // Two dropped frames, well inside the grace period.
    #expect(smoother.smooth(nil, now: 20 / 30.0) != nil)
    #expect(smoother.smooth(nil, now: 21 / 30.0) != nil)
}

@Test("The outline is dropped once the page is really gone")
func sustainedDropoutClearsOutline() {
    var smoother = QuadSmoother()
    for frame in 0..<20 {
        _ = smoother.smooth(page(), now: Double(frame) / 30)
    }
    #expect(smoother.smooth(nil, now: 20 / 30.0 + 0.5) == nil)
}

// MARK: - Choosing between competing rectangles

import CoreGraphics

/// A small printed item resting on a larger ruled sheet, on a busy ground —
/// the arrangement a voucher on a notepad on a rug produces.
func nestedDocumentScene(withInnerItem: Bool) -> CGImage {
    let width = 1200, height = 1600
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Patterned ground.
    for y in stride(from: 0, to: height, by: 14) {
        for x in stride(from: 0, to: width, by: 14) {
            context.setFillColor(CGColor(
                red: 0.35 + 0.45 * abs(sin(Double(x) * 0.11 + Double(y) * 0.07)),
                green: 0.20 + 0.35 * abs(cos(Double(x) * 0.08)),
                blue: 0.25 + 0.40 * abs(sin(Double(y) * 0.09)),
                alpha: 1
            ))
            context.fill(CGRect(x: x, y: y, width: 14, height: 14))
        }
    }

    // The ruled sheet, running off the top and bottom so it is not a full quad.
    context.setFillColor(CGColor(red: 0.80, green: 0.87, blue: 0.94, alpha: 1))
    context.fill(CGRect(x: 60, y: -120, width: 1020, height: 1840))
    context.setStrokeColor(CGColor(red: 0.62, green: 0.72, blue: 0.84, alpha: 1))
    context.setLineWidth(2)
    for y in stride(from: 0, to: height, by: 34) {
        context.move(to: CGPoint(x: 70, y: Double(y)))
        context.addLine(to: CGPoint(x: 1070, y: Double(y)))
    }
    context.strokePath()

    if withInnerItem {
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: 470, y: 600, width: 280, height: 400))
        context.setFillColor(CGColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1))
        for y in stride(from: 640, to: 960, by: 26) {
            context.fill(CGRect(x: 495, y: y, width: 200, height: 5))
        }
    }
    return context.makeImage()!
}

@Test("The small printed item wins over the sheet it rests on")
func picksTheItemNotTheSurface() async throws {
    // Vision's segmenter returns one answer and, on nested rectangles, reliably
    // returns the largest — a voucher on a notepad comes back as the notepad,
    // confidently. Competing scanners get this right from every angle, and not
    // by finding edges better: they judge which candidate is document-like.
    // Gathering alternatives and scoring them recovers that judgement.
    let scene = nestedDocumentScene(withInnerItem: true)
    let best = try await DocumentCandidateSelector().best(in: scene)
    let chosen = try #require(best)

    // The item covers 0.058 of the frame; the sheet covers about 0.84.
    #expect(chosen.quad.area < 0.2, "picked something covering \(chosen.quad.area) of the frame")
    let centre = chosen.quad.boundingBox
    #expect(abs(centre.midX - 0.51) < 0.08 && abs(centre.midY - 0.50) < 0.08)
}

@Test("A page that fills the frame is still chosen when it is the subject")
func picksThePageWhenItIsTheSubject() async throws {
    // The scorer penalises candidates that fill the frame, because those are
    // usually the surface. That must not cost the ordinary case, where the
    // document really is the whole picture.
    let scene = nestedDocumentScene(withInnerItem: false)
    let candidates = try await DocumentCandidateSelector().candidates(in: scene)
    let chosen = try #require(candidates.first)
    #expect(chosen.quad.area > 0.4, "rejected the only document present")
}
