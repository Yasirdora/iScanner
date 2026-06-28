import Testing
import Foundation
import CoreGraphics
import ScanCapture

/// A page at a given offset, the same helper shape the stabiliser tests use.
private func quad(offset: CGFloat = 0, inset: CGFloat = 0.2) -> DocumentQuad {
    DocumentQuad(
        topLeft: CGPoint(x: inset + offset, y: 1 - inset),
        topRight: CGPoint(x: 1 - inset + offset, y: 1 - inset),
        bottomRight: CGPoint(x: 1 - inset + offset, y: inset),
        bottomLeft: CGPoint(x: inset + offset, y: inset)
    )
}

@Test("The cheap reading carries the outline until a precise one arrives")
func fastReadingCarriesTheViewfinder() {
    var tracker = DocumentTracker()
    tracker.record(fast: quad(), at: 0)
    #expect(tracker.quad(at: 0.05) != nil)
    #expect(tracker.isPrecise(at: 0.05) == false)
}

@Test("A precise reading takes over while it is fresh")
func preciseReadingWins() {
    // The expensive detector is the only one that finds a small item, so its
    // answer must outrank the cheap one that found the sheet underneath.
    var tracker = DocumentTracker()
    let sheet = quad(inset: 0.05)
    let card = quad(inset: 0.38)

    tracker.record(fast: sheet, at: 0)
    tracker.record(precise: card, at: 0.1)

    let shown = tracker.quad(at: 0.2)
    #expect(shown?.area == card.area)
    #expect(tracker.isPrecise(at: 0.2))
}

@Test("A stale precise reading is abandoned")
func preciseReadingExpires() {
    var tracker = DocumentTracker()
    let sheet = quad(inset: 0.05)
    tracker.record(precise: quad(inset: 0.38), at: 0)
    tracker.record(fast: sheet, at: 2.5)

    #expect(tracker.isPrecise(at: 2.5) == false)
    #expect(tracker.quad(at: 2.5)?.area == sheet.area)
}

@Test("Pointing the phone elsewhere abandons the precise reading immediately")
func sceneChangeAbandonsPreciseReading() {
    // Otherwise the outline keeps describing a card that is no longer in shot,
    // for as long as its lifetime lasts.
    var tracker = DocumentTracker()
    tracker.record(fast: quad(offset: 0), at: 0)
    tracker.record(precise: quad(inset: 0.38), at: 0.1)

    // The cheap detector now sees the page a long way from where it was.
    tracker.record(fast: quad(offset: 0.4), at: 0.3)

    #expect(tracker.isPrecise(at: 0.3) == false)
    #expect(tracker.quad(at: 0.3)?.boundingBox.midX ?? 0 > 0.6)
}

@Test("Small movement keeps the precise reading")
func smallMovementKeepsPreciseReading() {
    var tracker = DocumentTracker()
    tracker.record(fast: quad(offset: 0), at: 0)
    tracker.record(precise: quad(inset: 0.38), at: 0.1)
    tracker.record(fast: quad(offset: 0.02), at: 0.3)

    #expect(tracker.isPrecise(at: 0.3))
}

@Test("Everything going stale clears the outline")
func staleReadingsClearTheOutline() {
    var tracker = DocumentTracker()
    tracker.record(fast: quad(), at: 0)
    tracker.record(precise: quad(inset: 0.38), at: 0)
    #expect(tracker.quad(at: 5) == nil)
}

@Test("A failed precise pass leaves the last good outline alone")
func failedPreciseReadingDoesNotErase() {
    // The reported symptom: move the phone slightly and the box disappears.
    // Motion blurs the print, the expensive detector finds no text, and
    // recording that failure used to wipe the outline it had a moment before.
    var tracker = DocumentTracker()
    let card = quad(inset: 0.38)

    tracker.record(precise: card, at: 0)
    tracker.record(precise: nil, at: 0.7)

    #expect(tracker.quad(at: 0.8)?.area == card.area)
    #expect(tracker.isPrecise(at: 0.8))
}

@Test("A precise reading can still be dropped deliberately")
func preciseReadingCanBeInvalidated() {
    var tracker = DocumentTracker()
    tracker.record(precise: quad(inset: 0.38), at: 0)
    tracker.invalidatePrecise()
    #expect(tracker.quad(at: 0.1) == nil)
}
