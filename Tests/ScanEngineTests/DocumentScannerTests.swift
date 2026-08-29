import Testing
import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import ScanEngine

// `DocumentScanner` is the one call most callers use, so these tests read it
// the way a caller would: give it a photo, check what comes back. Error-rate
// limits follow AccuracyTests — measured with Xcode 27.0, plus the same margin.

/// The clean receipt photographed at an angle: drawn in perspective onto a
/// dark table so it covers about half the frame, as a phone photo would.
private func photographedReceipt() throws -> CGImage {
    let width = 2400.0, height = 3000.0
    let tilt = CIFilter.perspectiveTransform()
    tilt.inputImage = CIImage(cgImage: try knownPage("receipt-clean"))
    tilt.topLeft = CGPoint(x: 0.22 * width, y: 0.84 * height)
    tilt.topRight = CGPoint(x: 0.74 * width, y: 0.80 * height)
    tilt.bottomRight = CGPoint(x: 0.80 * width, y: 0.16 * height)
    tilt.bottomLeft = CGPoint(x: 0.16 * width, y: 0.20 * height)
    let frame = CGRect(x: 0, y: 0, width: width, height: height)
    let table = CIImage(color: CIColor(red: 0.18, green: 0.15, blue: 0.13)).cropped(to: frame)
    let scene = try #require(tilt.outputImage).composited(over: table)
    return try #require(CIContext().createCGImage(scene, from: frame))
}

/// The clean receipt cut close to its print and laid flat on a plain dark
/// table, so the print's own estimate of the page reaches past the page.
private func pageOnAPlainTable() throws -> CGImage {
    let page = try #require(try knownPage("receipt-clean").cropping(to: CGRect(x: 136, y: 140, width: 994, height: 1370)))
    let width = 2000, height = 2600
    let context = try #require(CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.18, green: 0.15, blue: 0.13, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(page, in: CGRect(x: (width - page.width) / 2, y: (height - page.height) / 2, width: page.width, height: page.height))
    return try #require(context.makeImage())
}

/// A photo with nothing in it: an even grey surface.
private func emptySurface() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 1200, height: 1600,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.50, green: 0.48, blue: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
    return try #require(context.makeImage())
}

private func errorRate(of page: ScannedPage) throws -> Double {
    TextAccuracy.characterErrorRate(recognized: page.text, truth: try knownTranscript("receipt"))
}

@Test("A page photographed at an angle is found, straightened and read")
func photographedPageIsScanned() async throws {
    let page = try await DocumentScanner().scan(try photographedReceipt())

    #expect(page.wasPageFound)
    #expect(page.image.height > page.image.width, "came out \(page.image.width)x\(page.image.height), not upright")
    // Measured 0.0115 with the style Auto chose (Enhance).
    let rate = try errorRate(of: page)
    #expect(rate <= 0.0115 + AccuracyCase.margin, "error rate \(rate)")
}

@Test("A requested style is used as asked")
func requestedStyleIsUsed() async throws {
    let page = try await DocumentScanner(options: .init(style: .bitonal)).scan(try photographedReceipt())
    #expect(page.style == .bitonal)
    // Measured 0.0000: Ink reads this page perfectly.
    #expect(try errorRate(of: page) <= AccuracyCase.margin)
}

@Test("Auto reports the style it chose, never Auto itself")
func autoReportsItsChoice() async throws {
    let flat = DocumentScanner(options: .init(findsPage: false))
    // Measured: Colour for the clean receipt, Enhance for the shadowed one.
    #expect(try await flat.scan(try knownPage("receipt-clean")).style == .color)
    #expect(try await flat.scan(try knownPage("receipt-hard")).style == .enhanced)
}

@Test("With page finding off, a flat page is cleaned as it is and read within its limit",
      arguments: [("receipt", 0.0057), ("receipt-clean", 0.0057), ("receipt-hard", 0.0229), ("receipt-hard-4k", 0.0201)])
func flatPageIsReadWhole(_ name: String, _ measured: Double) async throws {
    let photo = try knownPage(name)
    let page = try await DocumentScanner(options: .init(findsPage: false)).scan(photo)

    #expect(!page.wasPageFound)
    #expect(page.image.width == photo.width && page.image.height == photo.height)
    let rate = try errorRate(of: page)
    #expect(rate <= measured + AccuracyCase.margin, "\(name): error rate \(rate)")
}

@Test("A flat page that fills the frame is read whole with page finding on",
      arguments: [("receipt", 0.0057), ("receipt-clean", 0.0057), ("receipt-hard", 0.0229), ("receipt-hard-4k", 0.0201)])
func pageFillingTheFrameIsNotCropped(_ name: String, _ measured: Double) async throws {
    // This was a known issue. The finder took a region inside the page — the
    // segmenter's outline, cut along the shadow — and lost 0.21 to 0.32 of the
    // characters. Now the whole frame is the page, and the result matches
    // page finding off.
    let photo = try knownPage(name)
    let page = try await DocumentScanner().scan(photo)

    let outline = try #require(page.outline)
    #expect(outline.area > 0.99, "\(name): kept \(outline.area) of the page")
    #expect(page.image.width == photo.width && page.image.height == photo.height)
    let rate = try errorRate(of: page)
    #expect(rate <= measured + AccuracyCase.margin, "\(name): error rate \(rate)")
}

@Test("A page on a plain table is found by its edges, even when its print runs close to them")
func pageOnAPlainTableIsNotTakenWhole() async throws {
    // The table around the print has no edge in it, as a flat page has none.
    // What tells them apart is the page's own outline, which holds the print.
    // The page covers 0.262 of the photo as drawn; measured 0.258.
    let best = try #require(try await DocumentCandidateSelector().best(in: try pageOnAPlainTable()))
    #expect(best.source != .frame)
    #expect(abs(best.quad.area - 0.262) < 0.02, "took \(best.quad.area) of the photo")
}

@Test("A card on a notepad is found inside the photo, not taken whole",
      arguments: ["real/7792", "real/7793", "real/7794"])
func cardOnANotepadIsNotTakenWhole(_ name: String) async throws {
    // Three real photos: no outline around the card is seen, as on a flat
    // page, but the notepad's lines and the rug are edges. Measured: the card
    // covers 0.09 to 0.13 of the photo.
    let best = try #require(try await DocumentCandidateSelector().best(in: try knownPage(name)))
    #expect(best.source != .frame)
    #expect(best.quad.area < 0.2, "\(name): took \(best.quad.area) of the photo")
}

@Test("When no page is found, the whole photo is used and the result says so")
func noPageMeansTheWholePhoto() async throws {
    let photo = try emptySurface()
    let page = try await DocumentScanner().scan(photo)

    #expect(!page.wasPageFound)
    #expect(page.outline == nil)
    #expect(page.image.width == photo.width && page.image.height == photo.height)
    #expect(page.text.isEmpty)
}

@Test("Export writes one searchable PDF page per scanned page, with its title")
func exportWritesEveryPage() async throws {
    let scanner = DocumentScanner(options: .init(findsPage: false))
    let pages = [
        try await scanner.scan(try knownPage("receipt-clean")),
        try await scanner.scan(try knownPage("receipt")),
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scanner-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    try scanner.exportPDF(pages, to: url, title: "Two receipts")

    let document = try #require(PDFDocument(url: url))
    #expect(document.pageCount == 2)
    #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Two receipts")
    for index in 0..<2 {
        let text = try #require(document.page(at: index)?.string)
        #expect(text.contains("NORTHGATE HARDWARE") && text.contains("TOTAL"), "page \(index + 1): \(text)")
    }
}

@Test("Exporting no pages is refused instead of writing a blank page")
func exportRefusesNoPages() throws {
    // The PDF writer underneath produces one blank page for an empty list,
    // which looks like a scan that lost its content.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("scanner-\(UUID().uuidString).pdf")
    #expect(throws: ScanError.noPages) {
        try DocumentScanner().exportPDF([], to: url)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
