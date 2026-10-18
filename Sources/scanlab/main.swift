import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScanCore
import ScanCapture
import ScanEnhance
import ScanRecognize
import ScanExport
import ScanExtract

// A command-line harness for the scanning engine.
//
// The point of this tool is measurement. Enhancement quality is the one thing
// that separates this from the scanner already built into iOS, and "it looks
// better" is not a claim anyone can act on. `compare` runs every enhancement
// style through the same recogniser and reports what each one costs and what
// each one recovers, so a change to the pipeline either moves those numbers or
// it does not ship.

// MARK: - Image IO

func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CLIError.cannotRead(url)
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { throw CLIError.cannotWrite(url) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CLIError.cannotWrite(url) }
}

enum CLIError: Error, CustomStringConvertible {
    case cannotRead(URL)
    case cannotWrite(URL)
    case usage

    var description: String {
        switch self {
        case .cannotRead(let url): "Cannot read image at \(url.path)"
        case .cannotWrite(let url): "Cannot write to \(url.path)"
        case .usage: usageText
        }
    }
}

let usageText = """
scanlab — document scanning engine harness

USAGE
  scanlab process <image> [--style color|grayscale|bitonal|original]
                          [--gain <n>] [--out <dir>]
      Enhance, recognise, and export one page to a searchable PDF.

  scanlab compare <image> [--out <dir>]
      Run every enhancement style through the recogniser and report the
      timings, confidence, and — when a ground-truth <image>.txt sits beside
      the image — the character error rate for each.

  scanlab plate <image> [--out <dir>]
      Write the pipeline's intermediates: the colour mask, the colour-
      suppressed page, the illumination plate, and the corrected result.

  scanlab candidates <image> [--draw <out.png>]
      Rank every plausible page outline by how document-like it is.

  scanlab auto <image> [--style ...] [--out <dir>]
      The whole import path end to end: find the page, flatten it, enhance it,
      and write a searchable PDF.

  scanlab bench <image>
      Time each detector at the resolutions a live viewfinder would use, so a
      frame budget can be set from measurement rather than from hope.

  scanlab levels <image>
      Report what each filter does to a page: where the paper and ink land,
      and how much of the page is neither.

  scanlab extract <image>
      Enhance, recognise, then pull typed fields with the on-device model.

  scanlab synth <output.png> [--difficulty clean|normal|hard|colour|notes]
                             [--document receipt|invoice] [--on-table]
      Write a synthetic shadowed page plus its exact ground-truth transcript,
      for regressing the pipeline before a real corpus exists. `invoice` is a
      German bill; `--on-table` photographs the page at an angle on a table.
"""

// MARK: - Metrics

// Accuracy metrics live in ScanCore so the app can score itself in the field,
// not just the harness. See `TextAccuracy`.
func characterErrorRate(recognized: String, truth: String) -> Double {
    TextAccuracy.characterErrorRate(recognized: recognized, truth: truth)
}

func elapsedMs(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

func elapsedMs(_ body: () async throws -> Void) async rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try await body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

// MARK: - Argument parsing

struct Arguments {
    var command: String
    var input: URL
    var style: ScanStyle = .color
    var difficulty: String = "normal"
    var document: String = "receipt"
    var onTable = false
    var drawTo: URL?
    var inkGamma: Double = EnhancementOptions.default.inkGamma
    var asJSON = false
    var gain: Double = EnhancementOptions.default.maximumGain
    var outputDirectory: URL

    init(_ argv: [String]) throws {
        guard argv.count >= 3 else { throw CLIError.usage }
        command = argv[1]
        input = URL(fileURLWithPath: argv[2]).standardizedFileURL
        outputDirectory = input.deletingLastPathComponent().appendingPathComponent("out")

        var index = 3
        while index < argv.count {
            switch argv[index] {
            case "--style":
                guard index + 1 < argv.count, let parsed = ScanStyle(rawValue: argv[index + 1]) else {
                    throw CLIError.usage
                }
                style = parsed
                index += 2
            case "--difficulty":
                guard index + 1 < argv.count else { throw CLIError.usage }
                difficulty = argv[index + 1]
                index += 2
            case "--document":
                guard index + 1 < argv.count else { throw CLIError.usage }
                document = argv[index + 1]
                index += 2
            case "--on-table":
                onTable = true
                index += 1
            case "--json":
                asJSON = true
                index += 1
            case "--draw":
                guard index + 1 < argv.count else { throw CLIError.usage }
                drawTo = URL(fileURLWithPath: argv[index + 1])
                index += 2
            case "--ink":
                guard index + 1 < argv.count, let value = Double(argv[index + 1]) else {
                    throw CLIError.usage
                }
                inkGamma = value
                index += 2
            case "--gain":
                guard index + 1 < argv.count, let value = Double(argv[index + 1]) else {
                    throw CLIError.usage
                }
                gain = value
                index += 2
            case "--out":
                guard index + 1 < argv.count else { throw CLIError.usage }
                outputDirectory = URL(fileURLWithPath: argv[index + 1])
                index += 2
            default:
                throw CLIError.usage
            }
        }
    }
}

// MARK: - Commands

func groundTruth(for input: URL) -> String? {
    let candidate = input.deletingPathExtension().appendingPathExtension("txt")
    return try? String(contentsOf: candidate, encoding: .utf8)
}

func process(_ args: Arguments) async throws {
    let image = try loadImage(args.input)
    try FileManager.default.createDirectory(at: args.outputDirectory, withIntermediateDirectories: true)

    var timings = StageTimings()
    var enhanced: CGImage = image
    let resolved = args.style == .auto
        ? try DocumentEnhancer().chooseStyle(for: image)
        : args.style
    var options = EnhancementOptions.preset(for: resolved)
    if args.gain != EnhancementOptions.default.maximumGain { options.maximumGain = args.gain }
    if args.inkGamma != EnhancementOptions.default.inkGamma { options.inkGamma = args.inkGamma }
    timings.enhanceMs = try elapsedMs {
        enhanced = try DocumentEnhancer().enhance(image, style: resolved, options: options)
    }

    var recognition = PageRecognition()
    timings.recognizeMs = try await elapsedMs {
        recognition = try await DocumentRecognizer().recognize(enhanced)
    }

    let stem = args.input.deletingPathExtension().lastPathComponent
    let pngURL = args.outputDirectory.appendingPathComponent("\(stem)-\(args.style.rawValue).png")
    let pdfURL = args.outputDirectory.appendingPathComponent("\(stem)-\(args.style.rawValue).pdf")
    if args.style == .auto { print("  auto chose  \(resolved.rawValue)") }

    try writePNG(enhanced, to: pngURL)
    timings.exportMs = try elapsedMs {
        try SearchablePDFBuilder().write(
            pages: [.init(image: enhanced, recognition: recognition)],
            to: pdfURL,
            metadata: .init(title: stem)
        )
    }

    print("""
    \(args.input.lastPathComponent)  [\(args.style.rawValue)]
      size        \(image.width)x\(image.height)
      text runs   \(recognition.runs.count)
      characters  \(recognition.transcript.count)
      tables      \(recognition.tables.count)
      detected    \(recognition.detected.count)
      barcodes    \(recognition.barcodes.count)
      enhance     \(String(format: "%.0f", timings.enhanceMs)) ms
      recognize   \(String(format: "%.0f", timings.recognizeMs)) ms
      export      \(String(format: "%.0f", timings.exportMs)) ms
      png         \(pngURL.path)
      pdf         \(pdfURL.path)
    """)

    if let truth = groundTruth(for: args.input) {
        let cer = characterErrorRate(recognized: recognition.transcript, truth: truth)
        print("  CER         \(String(format: "%.3f", cer))")
    }
}

/// Fixed-width table row. `String(format:)` does not honour a field width for
/// `%@` on all platforms, so the padding is done here instead.
func row(_ cells: String...) -> String {
    let widths = [10, 10, 11, 8, 8, 8, 8]
    return zip(cells, widths)
        .map { $0.padding(toLength: max($1, $0.count), withPad: " ", startingAt: 0) }
        .joined(separator: " ")
}

func compare(_ args: Arguments) async throws {
    let image = try loadImage(args.input)
    try FileManager.default.createDirectory(at: args.outputDirectory, withIntermediateDirectories: true)
    let truth = groundTruth(for: args.input)
    let enhancer = DocumentEnhancer()
    let recognizer = DocumentRecognizer()
    let stem = args.input.deletingPathExtension().lastPathComponent

    print("\(args.input.lastPathComponent) — \(image.width)x\(image.height)")
    print(truth == nil
        ? "no ground truth found; reporting confidence and yield only\n"
        : "ground truth found; reporting character error rate\n")
    // Vision loads its recognition model on first use, which costs seconds and
    // would otherwise be charged to whichever style happens to run first.
    _ = try await recognizer.recognize(image)

    print(row("style", "enhance", "recognize", "chars", "conf", "CER", "png"))

    for style in ScanStyle.offered + [.original] {
        var enhanced: CGImage = image
        let enhanceMs = try elapsedMs {
            enhanced = try enhancer.enhance(image, style: style, options: .preset(for: style))
        }
        var recognition = PageRecognition()
        let recognizeMs = try await elapsedMs {
            recognition = try await recognizer.recognize(enhanced)
        }

        let pngURL = args.outputDirectory.appendingPathComponent("\(stem)-\(style.rawValue).png")
        try writePNG(enhanced, to: pngURL)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: pngURL.path)[.size] as? Int) ?? 0

        let confidence = recognition.runs.isEmpty
            ? 0
            : recognition.runs.reduce(0) { $0 + Double($1.confidence) } / Double(recognition.runs.count)
        let cer = truth.map { characterErrorRate(recognized: recognition.transcript, truth: $0) }

        print(row(
            style.rawValue,
            String(format: "%.0fms", enhanceMs),
            String(format: "%.0fms", recognizeMs),
            "\(recognition.transcript.count)",
            String(format: "%.3f", confidence),
            cer.map { String(format: "%.3f", $0) } ?? "—",
            "\(bytes / 1024)KB"
        ))
    }
}

func extract(_ args: Arguments) async throws {
    let image = try loadImage(args.input)
    let enhanced = try DocumentEnhancer().enhance(image, style: args.style)
    let recognition = try await DocumentRecognizer().recognize(enhanced)

    let extractor = FoundationModelExtractor()
    guard extractor.isAvailable else {
        print("On-device model unavailable on this machine. Recognition still ran:")
        print(recognition.transcript.prefix(500))
        return
    }

    let kind = try await extractor.classify(recognition)
    let title = try await extractor.suggestTitle(for: recognition)
    print("kind:  \(kind.rawValue)")
    print("title: \(title)")

    if kind == .receipt || kind == .invoice {
        let receipt = try await extractor.extractReceipt(from: recognition)
        let json = try JSONEncoder().encode(receipt)
        print("receipt: \(String(data: json, encoding: .utf8) ?? "")")
    }
}

func synth(_ args: Arguments) throws {
    let difficulty = Synthesizer.Difficulty(rawValue: args.difficulty) ?? .normal
    guard let document = Synthesizer.Document(rawValue: args.document) else { throw CLIError.usage }
    // The invoice has its own layout; the colour marks and the ruled notes page
    // are drawn for the receipt only.
    if document != .receipt && difficulty.hasColour { throw CLIError.usage }
    let page = try Synthesizer.makePage(difficulty: difficulty, document: document, onTable: args.onTable)
    let output = args.input
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try writePNG(page, to: output)

    // No ground truth for the colour fixture. Its marks sit over the page and
    // change how Vision groups the layout — with the stamp present the
    // transcript comes back column-major ("QTY 2 1 4 ... ITEM Cedar plank ...")
    // rather than row by row, which scores as a third of the characters wrong
    // on every style equally. That is a property of RecognizeDocumentsRequest's
    // table handling, not of any filter, and a permanent floor under the
    // accuracy number would hide real regressions beneath it. This fixture
    // measures colour; the other three measure accuracy.
    let truthURL = output.deletingPathExtension().appendingPathExtension("txt")
    if difficulty.hasColour {
        try? FileManager.default.removeItem(at: truthURL)
    } else {
        try Synthesizer.groundTruth(for: difficulty, document: document)
            .write(to: truthURL, atomically: true, encoding: .utf8)
    }

    print("wrote \(output.path)")
    print("wrote \(truthURL.path)")
}

func levels(_ args: Arguments) throws {
    let image = try loadImage(args.input)
    let enhancer = DocumentEnhancer()

    print("\(args.input.lastPathComponent) — \(image.width)x\(image.height)")
    print("target: paper >= 0.960, ink <= 0.140, midtones < 12%\n")
    let sourceColour = measureColour(image)
    print(formatLevels("as shot", measureLevels(image)))
    for style in ScanStyle.offered where style != .auto {
        let enhanced = try enhancer.enhance(image, style: style, options: .preset(for: style))
        print(formatLevels(style.rawValue, measureLevels(enhanced)))
    }

    print("\ncolour retention (of pixels that started coloured)")
    print(String(format: "  as shot    saturation %.3f over %.1f%% of the page",
                 sourceColour.meanSaturation, sourceColour.colouredFraction * 100))
    for style in [ScanStyle.color, .grayscale] {
        let enhanced = try enhancer.enhance(image, style: style)
        let colour = measureColour(enhanced)
        print(String(format: "  %-10@ saturation %.3f over %.1f%% of the page",
                     style.rawValue as NSString, colour.meanSaturation, colour.colouredFraction * 100))
    }
}

func plate(_ args: Arguments) throws {
    let image = try loadImage(args.input)
    try FileManager.default.createDirectory(at: args.outputDirectory, withIntermediateDirectories: true)
    let stem = args.input.deletingPathExtension().lastPathComponent
    let parts = try DocumentEnhancer().intermediates(image)

    for (name, part) in [
        ("mask", parts.colourMask),
        ("content", parts.contentMask),
        ("suppressed", parts.suppressed),
        ("plate", parts.plate),
        ("corrected", parts.corrected),
    ] {
        let url = args.outputDirectory.appendingPathComponent("\(stem)-\(name).png")
        try writePNG(part, to: url)
        print("wrote \(url.path)")
    }
}

/// Draws the ranked candidates over the page: the winner solid, the rest
/// dashed and fainter. A score table cannot say whether the chosen quad is the
/// right object; only looking at it can.
func draw(_ candidates: [DocumentCandidate], on image: CGImage) -> CGImage {
    let width = image.width, height = image.height
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.setLineWidth(max(4, CGFloat(width) / 300))

    for (rank, candidate) in candidates.prefix(4).enumerated().reversed() {
        let points = candidate.quad.corners.map {
            CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height))
        }
        if rank == 0 {
            context.setStrokeColor(CGColor(red: 0.1, green: 0.9, blue: 0.5, alpha: 1))
            context.setLineDash(phase: 0, lengths: [])
        } else {
            context.setStrokeColor(CGColor(red: 1, green: 0.35, blue: 0.3, alpha: 0.65))
            context.setLineDash(phase: 0, lengths: [18, 14])
        }
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.closePath()
        context.strokePath()
    }
    return context.makeImage() ?? image
}

func candidates(_ args: Arguments) async throws {
    let image = try loadImage(args.input)
    let found = try await DocumentCandidateSelector().candidates(in: image)

    let counts = try await DocumentCandidateSelector().signalCounts(in: image)
    print("\(args.input.lastPathComponent) — \(found.count) candidates, best first")
    print("signals: \(counts.rectangles) rectangles, segmentation=\(counts.hasSegmentation), \(counts.textBoxes) text boxes, \(counts.salientBoxes) salient objects\n")
    print(String(format: "%-14@ %8@ %8@ %8@ %8@ %8@",
                 "source" as NSString, "score" as NSString, "contains" as NSString,
                 "salient" as NSString, "area" as NSString, "centre" as NSString))
    if let output = args.drawTo {
        try writePNG(draw(found, on: image), to: output)
        print("drew top candidates to \(output.path)\n")
    }

    if args.asJSON {
        let best = found.first
        let box = best?.quad.boundingBox ?? .zero
        print("{\"minX\":\(box.minX),\"minY\":\(box.minY),\"maxX\":\(box.maxX),\"maxY\":\(box.maxY),\"source\":\"\(best?.source.rawValue ?? "none")\"}")
        return
    }

    for candidate in found.prefix(8) {
        let box = candidate.quad.boundingBox
        print(String(format: "%-14@ %8.3f %8.3f %8.3f %8.3f   %.2f,%.2f",
                     candidate.source.rawValue as NSString,
                     candidate.score, candidate.textContainment, candidate.saliency,
                     candidate.quad.area, box.midX, box.midY))
    }
}

func auto(_ args: Arguments) async throws {
    let image = try loadImage(args.input)
    try FileManager.default.createDirectory(at: args.outputDirectory, withIntermediateDirectories: true)
    let stem = args.input.deletingPathExtension().lastPathComponent

    guard let found = try await DocumentCandidateSelector().best(in: image) else {
        print("no page found")
        return
    }
    let flattened = try PerspectiveRectifier().rectify(
        image,
        topLeft: found.quad.topLeft,
        topRight: found.quad.topRight,
        bottomRight: found.quad.bottomRight,
        bottomLeft: found.quad.bottomLeft
    )
    let enhanced = try DocumentEnhancer().enhance(flattened, style: args.style)
    let recognition = try await DocumentRecognizer().recognize(enhanced)

    let png = args.outputDirectory.appendingPathComponent("\(stem)-auto.png")
    try writePNG(enhanced, to: png)
    try SearchablePDFBuilder().write(
        pages: [.init(image: enhanced, recognition: recognition)],
        to: args.outputDirectory.appendingPathComponent("\(stem)-auto.pdf"),
        metadata: .init(title: stem)
    )
    print("""
    \(args.input.lastPathComponent)
      source     \(found.source.rawValue), score \(String(format: "%.3f", found.score))
      cropped    \(flattened.width)x\(flattened.height)
      characters \(recognition.transcript.count)
      png        \(png.path)
    """)
    print("  read: \(recognition.transcript.replacingOccurrences(of: "\n", with: " ").prefix(140))")
}

func bench(_ args: Arguments) async throws {
    let full = try loadImage(args.input)
    let detector = DocumentDetector()
    let selector = DocumentCandidateSelector()

    print("\(args.input.lastPathComponent) — median of 5 runs\n")
    print(String(format: "%-8@ %-22@ %10@", "width" as NSString, "detector" as NSString, "median" as NSString))

    for width in [512, 768, 1024] {
        guard let scaled = full.downscaled(toWidth: width) else { continue }

        var segmentation: [Double] = []
        var candidates: [Double] = []
        for _ in 0..<5 {
            segmentation.append(await elapsedMs {
                _ = try? await detector.detect(in: scaled, regionOfInterest: nil)
            })
            candidates.append(await elapsedMs {
                _ = try? await selector.best(in: scaled)
            })
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print(String(format: "%-8d %-22@ %8.0f ms", width, "segmentation" as NSString, median(segmentation)))
        print(String(format: "%-8d %-22@ %8.0f ms", width, "candidate selector" as NSString, median(candidates)))
    }
}


// MARK: - Entry point

do {
    let args = try Arguments(CommandLine.arguments)
    switch args.command {
    case "process": try await process(args)
    case "compare": try await compare(args)
    case "levels": try levels(args)
    case "candidates": try await candidates(args)
    case "auto": try await auto(args)
    case "bench": try await bench(args)
    case "plate": try plate(args)
    case "extract": try await extract(args)
    case "synth": try synth(args)
    default: throw CLIError.usage
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
