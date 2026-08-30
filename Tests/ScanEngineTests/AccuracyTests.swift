import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScanCore
import ScanEnhance
import ScanRecognize

// `scanlab compare` measures how well each style reads; these tests make the
// measurement a guard. Every page here has an exact transcript beside it
// (written by `scanlab synth`), so the character error rate is a fact, not an
// opinion.
//
// The limits are what the engine measured with Xcode 27.0 on an Apple silicon
// Mac, plus 0.012 — about four characters of the receipt's ~350. That margin
// absorbs small differences between machines; a broken stage costs many more
// characters than that.

/// A test page in `Fixtures/`.
func knownPage(_ name: String) throws -> CGImage {
    let url = fixturesFolder().appendingPathComponent("\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    return image
}

/// The exact text printed on a test page.
func knownTranscript(_ name: String) throws -> String {
    try String(contentsOf: fixturesFolder().appendingPathComponent("\(name).txt"), encoding: .utf8)
}

private func fixturesFolder() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ScanEngineTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Fixtures")
}

/// One page read in one style, with the error rate measured for it.
struct AccuracyCase: CustomTestStringConvertible, Sendable {
    let page: String
    let style: ScanStyle
    let measured: Double

    static let margin = 0.012
    var limit: Double { measured + Self.margin }
    var testDescription: String { "\(page) · \(style.title)" }

    /// Measured the way a caller reads a page: enhance in the style — Auto
    /// first reads the page and chooses one — recognise, compare against the
    /// transcript.
    static let all: [AccuracyCase] = [
        // An ordinary capture: some shadow, nothing extreme.
        .init(page: "receipt", style: .auto, measured: 0.0057),  // chooses Colour
        .init(page: "receipt", style: .enhanced, measured: 0.0057),
        .init(page: "receipt", style: .color, measured: 0.0057),
        .init(page: "receipt", style: .light, measured: 0.0115),
        .init(page: "receipt", style: .grayscale, measured: 0.0057),
        .init(page: "receipt", style: .bitonal, measured: 0.0143),
        .init(page: "receipt", style: .original, measured: 0.0172),
        // A clean capture.
        .init(page: "receipt-clean", style: .auto, measured: 0.0057),  // chooses Colour
        .init(page: "receipt-clean", style: .enhanced, measured: 0.0057),
        .init(page: "receipt-clean", style: .color, measured: 0.0057),
        .init(page: "receipt-clean", style: .light, measured: 0.0115),
        .init(page: "receipt-clean", style: .grayscale, measured: 0.0057),
        .init(page: "receipt-clean", style: .bitonal, measured: 0.0143),
        .init(page: "receipt-clean", style: .original, measured: 0.0172),
        // A heavy shadow. Here the photo as shot currently reads *better* than
        // every cleaned style — the README says so, and these limits pin both
        // sides so a change in either direction is seen.
        .init(page: "receipt-hard", style: .auto, measured: 0.0229),  // chooses Enhance
        .init(page: "receipt-hard", style: .enhanced, measured: 0.0229),
        .init(page: "receipt-hard", style: .color, measured: 0.0229),
        .init(page: "receipt-hard", style: .light, measured: 0.0258),
        .init(page: "receipt-hard", style: .grayscale, measured: 0.0229),
        .init(page: "receipt-hard", style: .bitonal, measured: 0.0229),
        .init(page: "receipt-hard", style: .original, measured: 0.0115),
        // The same heavy shadow at phone resolution.
        .init(page: "receipt-hard-4k", style: .auto, measured: 0.0201),  // chooses Enhance
        .init(page: "receipt-hard-4k", style: .enhanced, measured: 0.0201),
        .init(page: "receipt-hard-4k", style: .color, measured: 0.0115),
        .init(page: "receipt-hard-4k", style: .light, measured: 0.0172),
        .init(page: "receipt-hard-4k", style: .grayscale, measured: 0.0172),
        .init(page: "receipt-hard-4k", style: .bitonal, measured: 0.0229),
        .init(page: "receipt-hard-4k", style: .original, measured: 0.0172),
    ]
}

/// Error rate of one page read in one style.
///
/// The one-argument `enhance` is the call a caller makes: for Auto it reads the
/// page and chooses a style, then uses that style's preset. Passing `.auto`
/// with explicit options skips the choice and takes the Colour path, which is
/// what the Auto rows measured before: 0.0115 instead of 0.0201 at 4K.
private func errorRate(page: String, style: ScanStyle) async throws -> Double {
    let enhanced = try DocumentEnhancer().enhance(try knownPage(page), style: style)
    let reading = try await DocumentRecognizer().recognize(enhanced)
    return TextAccuracy.characterErrorRate(recognized: reading.transcript, truth: try knownTranscript(page))
}

/// Size of an image saved as PNG, the format the app and scanlab write.
private func pngSize(_ image: CGImage) throws -> Int {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data.length
}

@Test("Every known page reads within its error limit, in every style", arguments: AccuracyCase.all)
func readsWithinTheLimit(_ check: AccuracyCase) async throws {
    let rate = try await errorRate(page: check.page, style: check.style)
    #expect(rate <= check.limit,
            "\(check.page) in \(check.style.title): error rate \(rate), limit \(check.limit)")
}

@Test("On an ordinary page, the default style reads better than the photo as shot",
      arguments: ["receipt", "receipt-clean"])
func cleanupHelpsAnOrdinaryPage(_ page: String) async throws {
    // Measured: 0.0057 against 0.0172, about two characters wrong instead of
    // six. Not true of the heavy-shadow page — see the cases above.
    let cleaned = try await errorRate(page: page, style: .auto)
    let asShot = try await errorRate(page: page, style: .original)
    #expect(cleaned < asShot, "\(page): cleaned \(cleaned), as shot \(asShot)")
}

@Test("Ink is the smallest style, and at least four times smaller than the photo",
      arguments: ["receipt", "receipt-clean", "receipt-hard", "receipt-hard-4k"])
func inkGivesTheSmallestFile(_ page: String) throws {
    // Measured: 108 KB against 1199 KB on the ordinary receipt, 501 KB against
    // 4115 KB at 4K. The smallest ratio is the clean page, 107 KB against 499 KB.
    let image = try knownPage(page)
    let enhancer = DocumentEnhancer()
    var sizes: [ScanStyle: Int] = [:]
    for style in ScanStyle.offered + [.original] {
        sizes[style] = try pngSize(enhancer.enhance(image, style: style, options: .preset(for: style)))
    }
    let ink = try #require(sizes[.bitonal])
    let photo = try #require(sizes[.original])

    #expect(ink * 4 <= photo, "\(page): ink \(ink / 1024) KB, photo \(photo / 1024) KB")
    for (style, size) in sizes where style != .bitonal {
        #expect(ink < size, "\(page): \(style.title) at \(size / 1024) KB is smaller than ink at \(ink / 1024) KB")
    }
}
