import Testing
import Foundation
import CoreGraphics
import ScanCapture

// `DocumentQuad` is the shape every other stage agrees on: the detector
// produces it, the stabiliser measures it, the rectifier consumes it. Its
// geometry is pure arithmetic, so each property is checked against a shape
// whose answer is known without running the code.

/// An axis-aligned rectangle as a quad, in Vision's lower-left space.
private func rectangleQuad(x: Double, y: Double, width: Double, height: Double) -> DocumentQuad {
    DocumentQuad(
        topLeft: CGPoint(x: x, y: y + height),
        topRight: CGPoint(x: x + width, y: y + height),
        bottomRight: CGPoint(x: x + width, y: y),
        bottomLeft: CGPoint(x: x, y: y)
    )
}

/// A square of the given side, rotated 45° about the frame's centre — a page
/// lying diagonally, which is where a bounding box stops describing the page.
private func diamondQuad(side: Double) -> DocumentQuad {
    let reach = side / 2.0.squareRoot()
    return DocumentQuad(
        topLeft: CGPoint(x: 0.5, y: 0.5 + reach),
        topRight: CGPoint(x: 0.5 + reach, y: 0.5),
        bottomRight: CGPoint(x: 0.5, y: 0.5 - reach),
        bottomLeft: CGPoint(x: 0.5 - reach, y: 0.5)
    )
}

@Test("A page's area is the fraction of the frame it covers, at any angle")
func areaIsTheCoveredFraction() {
    #expect(abs(rectangleQuad(x: 0.1, y: 0.2, width: 0.5, height: 0.4).area - 0.20) < 1e-9)
    // Rotation changes the bounding box, never the area.
    #expect(abs(diamondQuad(side: 0.4).area - 0.16) < 1e-9)
}

@Test("The bounding box spans the page's outermost corners")
func boundingBoxSpansTheCorners() {
    let box = diamondQuad(side: 0.4).boundingBox
    let reach = 0.4 / 2.0.squareRoot()
    #expect(abs(box.minX - (0.5 - reach)) < 1e-9)
    #expect(abs(box.maxX - (0.5 + reach)) < 1e-9)
    #expect(abs(box.width - box.height) < 1e-9)
}

@Test("Corner drift is the largest distance any single corner moved")
func driftIsTheLargestCornerMove() {
    let before = rectangleQuad(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    var after = before
    after.topRight.x += 0.03
    after.topRight.y += 0.04   // a 3-4-5 move: exactly 0.05
    after.bottomLeft.x += 0.01

    #expect(abs(after.maximumCornerDrift(from: before) - 0.05) < 1e-9)
    #expect(before.maximumCornerDrift(from: before) == 0)
}

@Test("A point inside a diagonal page counts; a corner of its bounding box does not")
func containsFollowsTheRealOutline() {
    let page = diamondQuad(side: 0.4)
    #expect(page.contains(CGPoint(x: 0.5, y: 0.5)))

    // Inside the bounding box but outside the page itself: exactly the case
    // that made text beside a tilted voucher look as if it were printed on it.
    let box = page.boundingBox
    #expect(!page.contains(CGPoint(x: box.minX + 0.01, y: box.maxY - 0.01)))
    #expect(!page.contains(CGPoint(x: 0.95, y: 0.95)))
}

@Test("Overlap is one for the same page and zero for pages apart")
func overlapAtTheExtremes() {
    let page = rectangleQuad(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
    let elsewhere = rectangleQuad(x: 0.6, y: 0.6, width: 0.3, height: 0.3)
    #expect(abs(page.intersectionOverUnion(page) - 1) < 1e-9)
    #expect(page.intersectionOverUnion(elsewhere) == 0)
}

@Test("Two pages offset by half their width overlap by one third")
func overlapOfHalfShiftedPages() {
    // Intersection 0.5 of a page, union 1.5 of a page: one third.
    let page = rectangleQuad(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    let shifted = rectangleQuad(x: 0.4, y: 0.2, width: 0.4, height: 0.4)
    #expect(abs(page.intersectionOverUnion(shifted) - 1.0 / 3.0) < 1e-9)
}

@Test("A page shot square-on has no skew; a keystoned one does")
func skewMeasuresKeystoning() {
    #expect(rectangleQuad(x: 0.1, y: 0.1, width: 0.8, height: 0.6).skew < 1e-9)
    #expect(diamondQuad(side: 0.4).skew < 1e-9, "rotation alone is not skew")

    // Top edge half the length of the bottom edge: shot from low down.
    let keystoned = DocumentQuad(
        topLeft: CGPoint(x: 0.3, y: 0.8),
        topRight: CGPoint(x: 0.6, y: 0.8),
        bottomRight: CGPoint(x: 0.8, y: 0.2),
        bottomLeft: CGPoint(x: 0.2, y: 0.2)
    )
    #expect(abs(keystoned.skew - 1) < 1e-9)
}
