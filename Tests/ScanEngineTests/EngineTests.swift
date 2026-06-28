import Testing
import Foundation
import CoreGraphics
import CoreImage
import PDFKit
import ScanCore
@testable import ScanEnhance
import ScanExport

// MARK: - Helpers

/// A solid grey field with a strong left-to-right lighting ramp, and no ink.
/// Flat-field correction should flatten it; nothing else in the pipeline should
/// have an opinion about it.
func gradientImage(width: Int = 400, height: Int = 400) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<width {
        let level = 0.25 + 0.7 * Double(x) / Double(width - 1)
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    return context.makeImage()!
}

/// Two flat tones, dark on light, in known proportion.
func bimodalImage(darkFraction: Double = 0.3) -> CGImage {
    let size = 200
    let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: Int(Double(size) * darkFraction)))
    return context.makeImage()!
}

/// Standard deviation of row-mean luminance across the image's columns — a
/// direct measure of how uneven the lighting still is.
func horizontalUnevenness(_ image: CGImage) -> Double {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let columnMeans = (0..<width).map { x -> Double in
        var total = 0.0
        for y in 0..<height { total += Double(pixels[(y * width + x) * 4]) }
        return total / Double(height)
    }
    let mean = columnMeans.reduce(0, +) / Double(columnMeans.count)
    let variance = columnMeans.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(columnMeans.count)
    return variance.squareRoot()
}

// MARK: - Enhancement

@Test("Flat-field correction flattens a lighting ramp")
func flatFieldRemovesGradient() throws {
    let input = gradientImage()
    let before = horizontalUnevenness(input)

    let output = try DocumentEnhancer().enhance(input, style: .grayscale)
    let after = horizontalUnevenness(output)

    // The ramp spans a quarter to nearly full brightness, so `before` is large.
    // Correction should leave almost none of it.
    #expect(before > 30, "fixture should start badly lit, measured \(before)")
    #expect(after < before / 4, "unevenness went \(before) -> \(after)")
}

@Test("Otsu's threshold lands between the two tones")
func otsuSeparatesModes() throws {
    let enhancer = DocumentEnhancer()
    let threshold = try enhancer.otsuThreshold(CIImage(cgImage: bimodalImage()))
    #expect(threshold > 0.15 && threshold < 0.85, "threshold \(threshold) fell outside the ink/paper gap")
}

@Test("Bitonal output collapses to two tones")
func bitonalIsBinary() throws {
    let output = try DocumentEnhancer().enhance(bimodalImage(), style: .bitonal)

    var pixels = [UInt8](repeating: 0, count: output.width * output.height * 4)
    let context = CGContext(
        data: &pixels, width: output.width, height: output.height,
        bitsPerComponent: 8, bytesPerRow: output.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(output, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))

    let midtones = stride(from: 0, to: pixels.count, by: 4)
        .map { pixels[$0] }
        .filter { $0 > 40 && $0 < 215 }
    let fraction = Double(midtones.count) / Double(output.width * output.height)
    #expect(fraction < 0.02, "\(fraction * 100)% of pixels were neither ink nor paper")
}

@Test("The original style is a passthrough")
func originalIsUntouched() throws {
    let input = gradientImage()
    let output = try DocumentEnhancer().enhance(input, style: .original)
    #expect(output === input)
}

// MARK: - Searchable PDF

@Test("The PDF text layer is selectable and correctly ordered")
func pdfTextLayerRoundTrips() throws {
    let runs = [
        TextRun(text: "NORTHGATE HARDWARE", boundingBox: CGRect(x: 0.1, y: 0.90, width: 0.5, height: 0.03), confidence: 1),
        TextRun(text: "TOTAL 96.00", boundingBox: CGRect(x: 0.1, y: 0.40, width: 0.3, height: 0.03), confidence: 1),
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanengine-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [.init(image: gradientImage(width: 850, height: 1100),
                      recognition: PageRecognition(runs: runs))],
        to: url
    )

    let document = try #require(PDFDocument(url: url))
    #expect(document.pageCount == 1)

    let text = try #require(document.page(at: 0)?.string)
    #expect(text.contains("NORTHGATE HARDWARE"))
    #expect(text.contains("TOTAL 96.00"))

    // Reading order follows the page, not the array: the heading sits higher.
    let heading = try #require(text.range(of: "NORTHGATE"))
    let total = try #require(text.range(of: "TOTAL"))
    #expect(heading.lowerBound < total.lowerBound)

    // A found selection must land where the ink is. PDFKit reports selection
    // bounds in page space with a lower-left origin, matching Vision's boxes.
    let selection = try #require(document.findString("TOTAL 96.00", withOptions: []).first)
    let page = try #require(document.page(at: 0))
    let bounds = selection.bounds(for: page)
    let expectedY = 0.40 * page.bounds(for: .mediaBox).height
    #expect(abs(bounds.minY - expectedY) < 8, "text layer drifted: \(bounds.minY) vs \(expectedY)")
}

@Test("Runs that are empty or degenerate are skipped, not drawn")
func emptyRunsAreSkipped() throws {
    let runs = [
        TextRun(text: "   ", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.03), confidence: 1),
        TextRun(text: "kept", boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.2, height: 0.03), confidence: 1),
        TextRun(text: "degenerate", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0, height: 0), confidence: 1),
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanengine-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [.init(image: gradientImage(width: 400, height: 400),
                      recognition: PageRecognition(runs: runs))],
        to: url
    )

    let text = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
    #expect(text.contains("kept"))
    #expect(!text.contains("degenerate"))
}

// MARK: - Accuracy metrics

@Test("Character error rate ignores line wrapping")
func cerIgnoresWhitespace() {
    let rate = TextAccuracy.characterErrorRate(
        recognized: "hello   world\nagain",
        truth: "hello world again"
    )
    #expect(rate == 0)
}

@Test("Character error rate counts real substitutions")
func cerCountsSubstitutions() {
    let rate = TextAccuracy.characterErrorRate(recognized: "h3llo", truth: "hello")
    #expect(abs(rate - 0.2) < 0.001)
}

@Test("Character error rate handles an empty reading")
func cerHandlesEmptyRecognition() {
    #expect(TextAccuracy.characterErrorRate(recognized: "", truth: "abc") == 1)
    #expect(TextAccuracy.characterErrorRate(recognized: "", truth: "") == 0)
}

@Test("A near-blank page is not amplified into noise")
func blankPageStaysBlank() throws {
    // Regression: the contrast stretch used to divide by the page's tonal
    // range without a floor. On a sheet with no ink that range is close to
    // zero, so the reciprocal was enormous and turned faint sensor variation
    // into full-contrast banding.
    let size = 300
    let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<size {
        // A one-percent ripple, the scale of noise rather than of ink.
        let level = 0.88 + 0.01 * sin(Double(x) / 12)
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: size))
    }
    let blank = context.makeImage()!

    let output = try DocumentEnhancer().enhance(blank, style: .grayscale)
    #expect(horizontalUnevenness(output) < 12, "blank page picked up structure it did not have")
}

@Test("Flat-field correction alone removes the ramp, before any tone work")
func flatFieldInIsolation() throws {
    let enhancer = DocumentEnhancer()
    let input = gradientImage()
    let corrected = enhancer.flatFieldCorrect(CIImage(cgImage: input), options: .default)

    let rendered = try #require(CIContext().createCGImage(corrected, from: CIImage(cgImage: input).extent))
    let before = horizontalUnevenness(input)
    let after = horizontalUnevenness(rendered)

    #expect(after < before / 6, "division left \(after) of an original \(before)")
}

/// A lit page with ink on it: a lighting ramp crossed by dark bars whose
/// thickness scales with the image, standing in for glyph strokes.
func inkedPage(width: Int) -> CGImage {
    let height = width * 4 / 3
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in 0..<width {
        let level = 0.30 + 0.65 * Double(x) / Double(width - 1)
        context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }

    // Strokes are a fixed fraction of the page, exactly as real type is.
    let stroke = max(1, width / 200)
    let pitch = max(stroke * 5, width / 40)
    context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1))
    for y in stride(from: height / 6, to: height * 5 / 6, by: pitch) {
        context.fill(CGRect(x: width / 6, y: y, width: width * 2 / 3, height: stroke))
    }
    return context.makeImage()!
}

/// Renders an image to a fixed width and returns its luminance samples, so two
/// captures of different resolutions can be compared pixel for pixel.
func luminance(_ image: CGImage, atWidth width: Int) -> [Double] {
    let height = width * 4 / 3
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
}

/// Mean absolute difference between two equally sized luminance fields.
func meanAbsoluteDifference(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
}

@Test("Enhancement holds up at phone capture resolution")
func enhancementSurvivesHighResolution() throws {
    // Not a resolution-invariance test — that claim was investigated and did not
    // survive measurement. Fixed pixel radii scored the same or better than
    // radii scaled to image width, at 4032 px and at seven times the reference
    // stroke weight. This only pins the weaker, verified property: a capture at
    // phone resolution still comes out cleanly separated into ink and paper.
    let enhanced = try DocumentEnhancer().enhance(inkedPage(width: 3400), style: .grayscale)
    let samples = luminance(enhanced, atWidth: 500)
    let midtones = samples.filter { $0 > 0.28 && $0 < 0.78 }
    let fraction = Double(midtones.count) / Double(samples.count)
    #expect(fraction < 0.12, "\(fraction * 100)% of the page was neither ink nor paper")
}

// MARK: - Colour

/// A lit page carrying a large block of saturated colour, as a highlighter or a
/// shaded table cell would be.
func highlightedPage(width: Int = 900) -> CGImage {
    let height = width * 4 / 3
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Warm off-white paper, gently unevenly lit.
    for x in 0..<width {
        let level = 0.78 + 0.10 * Double(x) / Double(width - 1)
        context.setFillColor(CGColor(red: level, green: level * 0.98, blue: level * 0.93, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    // A block far wider than any ink-erasure radius.
    context.setFillColor(CGColor(red: 0.95, green: 0.86, blue: 0.26, alpha: 1))
    context.fill(CGRect(x: width / 6, y: height / 2 - height / 14, width: width * 2 / 3, height: height / 7))

    // Text. Without ink the page has almost no tonal range, the blank-page
    // guard correctly declines to stretch it, and the fixture would be testing
    // that guard rather than the colour path.
    let stroke = max(1, width / 180)
    context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
    for y in stride(from: height / 8, to: height * 7 / 8, by: height / 22) {
        context.fill(CGRect(x: width / 6, y: y, width: width * 2 / 3, height: stroke))
    }
    return context.makeImage()!
}

/// Saturation at a single point, as `(max - min) / max`.
func saturation(of image: CGImage, atX fractionX: Double, y fractionY: Double) -> Double {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &pixels, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    let x = Int(Double(image.width - 1) * fractionX)
    // Bitmap rows run top-down; the fraction is given from the top.
    let y = Int(Double(image.height - 1) * (1 - fractionY))
    let index = (y * image.width + x) * 4
    let r = Double(pixels[index]) / 255
    let g = Double(pixels[index + 1]) / 255
    let b = Double(pixels[index + 2]) / 255
    let maximum = max(r, g, b), minimum = min(r, g, b)
    guard maximum > 0 else { return 0 }
    return (maximum - minimum) / maximum
}

@Test("A block of colour keeps its fill, not just its edges")
func colourBlockIsNotHollowed() throws {
    // Regression: the illumination plate is found with a max filter, which
    // cannot tell bright colour from bright lighting. A highlighter, brighter
    // than the paper around it, was read as illumination and divided away —
    // and since the block was far wider than the filter's reach, only the rim
    // where the filter could still see paper survived. The result was a hollow
    // block with a coloured outline, which reads as the filter being broken.
    let source = highlightedPage()
    let enhanced = try DocumentEnhancer().enhance(source, style: .color)

    let centre = saturation(of: enhanced, atX: 0.5, y: 0.5)
    #expect(centre > 0.45, "the middle of the block washed out to \(centre)")
}

@Test("Colour is reproduced rather than inflated")
func colourIsNotOversaturated() throws {
    // The other half of the fault: a per-channel levels map subtracts the same
    // absolute black point from every channel, which is a far larger share of
    // the smallest one. Colours came back more vivid than they were ever
    // printed. The colour path uses a gain-only map, and gain leaves
    // `(max - min) / max` unchanged.
    let source = highlightedPage()
    let before = saturation(of: source, atX: 0.5, y: 0.5)
    let after = try saturation(of: DocumentEnhancer().enhance(source, style: .color), atX: 0.5, y: 0.5)

    #expect(after >= before * 0.9, "colour was lost: \(before) -> \(after)")
    #expect(after <= before * 1.25, "colour was inflated: \(before) -> \(after)")
}

@Test("Paper around a coloured block still goes to white")
func paperStillWhitensBesideColour() throws {
    // Protecting colour must not protect the paper with it, or the page keeps
    // its cast and stops reading as a scan.
    let enhanced = try DocumentEnhancer().enhance(highlightedPage(), style: .color)
    let samples = luminance(enhanced, atWidth: 300)
    let nearWhite = samples.filter { $0 > 0.97 }
    #expect(Double(nearWhite.count) / Double(samples.count) > 0.6)
}

@Test("Grey and ink styles discard colour entirely")
func monochromeStylesDropColour() throws {
    let source = highlightedPage()
    for style in [ScanStyle.grayscale, .bitonal] {
        let enhanced = try DocumentEnhancer().enhance(source, style: style)
        let centre = saturation(of: enhanced, atX: 0.5, y: 0.5)
        #expect(centre < 0.05, "\(style.rawValue) kept colour: \(centre)")
    }
}

// MARK: - Styles

/// A page of faint marks on lit paper: pencil-weight strokes that sit close to
/// paper level, which is what a linear tone map leaves grey.
func faintlyMarkedPage(width: Int = 700) -> CGImage {
    let height = width * 4 / 3
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Paper at a normal exposure, gently unevenly lit — the regime where the
    // content mask used to misfire.
    for x in 0..<width {
        let level = 0.62 + 0.14 * Double(x) / Double(width - 1)
        context.setFillColor(CGColor(red: level, green: level, blue: level * 0.98, alpha: 1))
        context.fill(CGRect(x: x, y: 0, width: 1, height: height))
    }
    // Marks only slightly darker than the paper.
    context.setStrokeColor(CGColor(red: 0.44, green: 0.44, blue: 0.46, alpha: 1))
    context.setLineWidth(3)
    for y in stride(from: height / 8, to: height * 7 / 8, by: height / 16) {
        context.move(to: CGPoint(x: width / 6, y: y))
        context.addLine(to: CGPoint(x: width * 5 / 6, y: y))
    }
    context.strokePath()
    return context.makeImage()!
}

/// Mean level of the marks — lower is darker.
func markDarkness(_ image: CGImage) -> Double {
    let samples = luminance(image, atWidth: 300)
    let marks = samples.filter { $0 < 0.88 }
    guard !marks.isEmpty else { return 1 }
    return marks.reduce(0, +) / Double(marks.count)
}

@Test("Enhance darkens faint marks that Colour leaves pale")
func enhanceDeepensFaintMarks() throws {
    // The reported failure: handwriting scanned to a washed-out grey. The tone
    // map's black point comes from the darkest ink on the page, so pencil
    // beside ballpoint lands near paper and stays there.
    let page = faintlyMarkedPage()
    let enhancer = DocumentEnhancer()

    let faithful = try enhancer.enhance(page, style: .color, options: .preset(for: .color))
    let punchy = try enhancer.enhance(page, style: .enhanced, options: .preset(for: .enhanced))

    #expect(markDarkness(punchy) < markDarkness(faithful) - 0.05,
            "Enhance \(markDarkness(punchy)) vs Colour \(markDarkness(faithful))")
}

@Test("Light leaves faint marks alone")
func lightPreservesFaintMarks() throws {
    let page = faintlyMarkedPage()
    let enhancer = DocumentEnhancer()

    let gentle = try enhancer.enhance(page, style: .light, options: .preset(for: .light))
    let punchy = try enhancer.enhance(page, style: .enhanced, options: .preset(for: .enhanced))

    #expect(markDarkness(gentle) > markDarkness(punchy))
}

@Test("Every style still turns the paper white")
func everyStyleWhitensPaper() throws {
    // Whatever a style does to the marks, the page behind them is the thing
    // that makes a scan read as a scan.
    let page = faintlyMarkedPage()
    for style in [ScanStyle.enhanced, .color, .light, .grayscale] {
        let output = try DocumentEnhancer().enhance(page, style: style, options: .preset(for: style))
        let samples = luminance(output, atWidth: 300)
        let white = samples.filter { $0 > 0.95 }
        #expect(Double(white.count) / Double(samples.count) > 0.5,
                "\(style.rawValue) left the paper grey")
    }
}

@Test("A page with no photographic content is not protected from toning")
func contentMaskDoesNotCoverAPlainPage() throws {
    // Regression, and a bad one. The mask that shields photographs from the
    // paper-whitening map used absolute midtone thresholds, while flat-field
    // correction deliberately preserves the capture's exposure — so an
    // ordinarily lit page came out mid-grey, landed inside the band, and the
    // mask covered *everything*. The aggressive path never ran on any normally
    // exposed page, which is why scans looked washed.
    let parts = try DocumentEnhancer().intermediates(faintlyMarkedPage())
    let mask = luminance(parts.contentMask, atWidth: 200)
    let protected = mask.reduce(0, +) / Double(mask.count)
    #expect(protected < 0.25, "\(protected * 100)% of a plain page was treated as photographic")
}

@Test("Auto picks the punchy style for faint marks and the faithful one for colour")
func autoChoosesByContent() throws {
    let enhancer = DocumentEnhancer()
    #expect(try enhancer.chooseStyle(for: faintlyMarkedPage()) == .enhanced)
    #expect(try enhancer.chooseStyle(for: highlightedPage()) == .color)
}

@Test("Text extracts without spurious gaps, whatever the run's proportions")
func pdfTextSurvivesExtraction() throws {
    // A smoke test, and honestly not a regression guard.
    //
    // Fitting runs by stretching the text matrix destroyed extraction on a real
    // scan: "INT. COFFEE SHOP" came back as "I N T .  C O F F E E  S H O P",
    // because wide gaps between glyphs read as spaces. Sizing the font instead
    // fixed it, verified against that page — old output spaced, new output
    // clean.
    //
    // It could not be reproduced in isolation. A single stretched run survives
    // extraction at up to six times natural width; the fault needs a page of
    // runs together, which suggests the reader decides spacing across a whole
    // page rather than per run. So this checks that extraction works at all,
    // and the property that actually broke is guarded by nothing here. Said
    // plainly because a test whose comment overstates it is worse than none.
    let runs = [
        TextRun(text: "INT. COFFEE SHOP - DAY",
                boundingBox: CGRect(x: 0.05, y: 0.80, width: 0.90, height: 0.02),
                confidence: 1),
        TextRun(text: "JAKE",
                boundingBox: CGRect(x: 0.40, y: 0.60, width: 0.12, height: 0.02),
                confidence: 1),
    ]
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanengine-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [.init(image: gradientImage(width: 850, height: 1100),
                      recognition: PageRecognition(runs: runs))],
        to: url
    )

    let text = try #require(PDFDocument(url: url)?.page(at: 0)?.string)
    #expect(text.contains("INT. COFFEE SHOP - DAY"), "extracted as: \(text)")
    #expect(text.contains("JAKE"))
}
