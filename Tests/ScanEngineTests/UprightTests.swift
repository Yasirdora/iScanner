import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import ScanCapture
import ScanEngine

// A page's top is where its print says it is. Edge detectors name an outline's
// corners by where they sit in the photo, so a page lying upside down, or an
// outline whose labels are a half turn off, came out of the rectifier upside
// down. The finder now renames every outline by the print inside it.

/// A line of print from `start` to `end` in Vision's lower-left space, with
/// its top edge on the left of the direction it reads in.
private func line(from start: CGPoint, to end: CGPoint, height: CGFloat = 0.02) -> DocumentCandidateSelector.TextLine {
    let dx = end.x - start.x, dy = end.y - start.y
    let length = hypot(dx, dy)
    let up = CGPoint(x: -dy / length * height, y: dx / length * height)
    let topLeft = CGPoint(x: start.x + up.x, y: start.y + up.y)
    let topRight = CGPoint(x: end.x + up.x, y: end.y + up.y)
    let xs = [start.x, end.x, topLeft.x, topRight.x], ys = [start.y, end.y, topLeft.y, topRight.y]
    let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    return .init(topLeft: topLeft, topRight: topRight, bottomRight: end, bottomLeft: start, boundingBox: box)
}

/// A square page in the middle of the photo, its corners named `turns`
/// quarter turns away from the right names.
private func page(namedOffBy turns: Int) -> DocumentQuad {
    let upright = [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.2)]
    let named = (0..<4).map { upright[($0 + turns) % 4] }
    return DocumentQuad(topLeft: named[0], topRight: named[1], bottomRight: named[2], bottomLeft: named[3])
}

@Test("An outline named off by any quarter turn is renamed so the print reads upright", arguments: 0..<4)
func outlineIsRenamedByItsPrint(_ turns: Int) {
    let printed = [
        line(from: CGPoint(x: 0.3, y: 0.7), to: CGPoint(x: 0.7, y: 0.7)),
        line(from: CGPoint(x: 0.3, y: 0.5), to: CGPoint(x: 0.7, y: 0.5)),
    ]
    let renamed = DocumentCandidateSelector.oriented(page(namedOffBy: turns), toRead: printed)
    #expect(renamed.topLeft == CGPoint(x: 0.2, y: 0.8))
    #expect(renamed.topRight == CGPoint(x: 0.8, y: 0.8))
    #expect(renamed.bottomRight == CGPoint(x: 0.8, y: 0.2))
}

@Test("A page lying upside down gets its top from the print, not from the photo")
func upsideDownPageIsTurned() {
    // The print reads right to left in the photo: the page lies upside down,
    // so its top is the photo's bottom edge.
    let printed = [
        line(from: CGPoint(x: 0.7, y: 0.3), to: CGPoint(x: 0.3, y: 0.3)),
        line(from: CGPoint(x: 0.7, y: 0.5), to: CGPoint(x: 0.3, y: 0.5)),
    ]
    let renamed = DocumentCandidateSelector.oriented(page(namedOffBy: 0), toRead: printed)
    #expect(renamed.topLeft == CGPoint(x: 0.8, y: 0.2))
    #expect(renamed.topRight == CGPoint(x: 0.2, y: 0.2))
}

@Test("An outline with no print inside it keeps its corners")
func outlineWithoutPrintIsLeftAlone() {
    let elsewhere = [line(from: CGPoint(x: 0.85, y: 0.95), to: CGPoint(x: 0.95, y: 0.95))]
    let outline = page(namedOffBy: 2)
    #expect(DocumentCandidateSelector.oriented(outline, toRead: elsewhere) == outline)
}

/// The photographed bill turned by quarter turns, as a phone held another way
/// would take it.
private func photographedBill(turnedBy quarterTurns: Int) throws -> CGImage {
    let source = CIImage(cgImage: try knownPage("invoice-photo"))
    let turned = source.oriented([.up, .left, .down, .right][quarterTurns])
    let placed = turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX, y: -turned.extent.minY))
    return try #require(CIContext().createCGImage(placed, from: placed.extent))
}

@Test("A photographed page comes out upright, whichever way the phone was held", .needsVision, arguments: 0..<4)
func scanComesOutUpright(_ quarterTurns: Int) async throws {
    var options = DocumentScanner.Options()
    options.recognition.languages = [Locale.Language(identifier: "de-DE")]
    let page = try await DocumentScanner(options: options).scan(try photographedBill(turnedBy: quarterTurns))

    // Upright means the letterhead is at the top and the total below it, in
    // the straightened page's lower-left space.
    let heading = try #require(page.recognition.runs.first { $0.text.contains("Musterfirma") })
    let total = try #require(page.recognition.runs.first { $0.text.contains("Gesamtbetrag") })
    #expect(heading.boundingBox.midY > 0.7, "letterhead at \(heading.boundingBox.midY)")
    #expect(heading.boundingBox.midY > total.boundingBox.midY)
    #expect(page.image.height > page.image.width)
}
