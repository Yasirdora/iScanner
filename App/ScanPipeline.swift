import Foundation
import UIKit
import ScanCore
import ScanCapture
import ScanEnhance
import ScanRecognize
import ScanExport
import ScanExtract

/// One page's worth of everything the engine produced, ready to show.
struct ScanResult: Identifiable {
    let id = UUID()
    var enhanced: UIImage
    var recognition: PageRecognition
    var timings: StageTimings
    var pdfURL: URL
    var extraction: String?
}

/// Runs a captured page through enhance → recognise → export.
@MainActor
@Observable
final class ScanPipeline {
    var style: ScanStyle = .auto
    var results: [ScanResult] = []
    var isRunning = false
    var failure: String?

    private let renderer = PageRenderer()
    /// The learned detector is optional: if the model is missing or fails to
    /// load, detection carries on with the other candidate sources.
    private let selector = DocumentCandidateSelector(cornerModel: CoreMLCornerDetector.bundled())
    private let recognizer = DocumentRecognizer()
    private let exporter = SearchablePDFBuilder()
    private let extractor = FoundationModelExtractor()

    var extractionAvailable: Bool { extractor.isAvailable }

    func run(on images: [UIImage]) async {
        guard !images.isEmpty else { return }
        isRunning = true
        failure = nil
        defer { isRunning = false }

        for image in images {
            do {
                results.append(try await process(image))
            } catch {
                failure = String(describing: error)
            }
        }
    }

    /// Resolution the page is found at.
    ///
    /// Detection depends on how much text Vision can read, and a 12-megapixel
    /// frame costs far more to search than it adds: at 1600 pixels the detector
    /// already finds every line on a printed card, and this is the size the
    /// result was verified at. The quad comes back normalised, so it applies to
    /// the full-resolution capture unchanged.
    private static let detectionWidth = 1600

    /// Finds the page inside a photograph.
    ///
    /// Used for imports and for the plain-shutter capture, both of which hand
    /// over a whole picture rather than a cropped page. Apple's segmenter
    /// returns nothing at all for a light card lying on light paper — measured
    /// on three real photographs — while the print on the card locates it
    /// reliably.
    func findDocument(in image: UIImage) async -> DocumentQuad? {
        guard let source = image.cgImage else { return nil }
        let searched = source.downscaled(toWidth: Self.detectionWidth) ?? source
        return try? await selector.best(in: searched)?.quad
    }

    /// Runs an imported photo, cropped to the corners the user confirmed.
    func run(imported image: UIImage, quad: DocumentQuad?) async {
        guard let source = image.cgImage else { return }
        isRunning = true
        failure = nil
        defer { isRunning = false }

        do {
            let flattened = try await renderer.flatten(SendableImage(source), quad: quad)
            results.append(try await finish(flattened))
        } catch {
            failure = String(describing: error)
        }
    }

    func clear() {
        results.removeAll()
        failure = nil
    }

    private func process(_ image: UIImage) async throws -> ScanResult {
        guard let source = image.cgImage else { throw PipelineError.noBitmap }
        // VisionKit already rectified and cropped the page, so scans go straight
        // to tone with no perspective step.
        return try await finish(SendableImage(source))
    }

    private func finish(_ page: SendableImage) async throws -> ScanResult {
        var timings = StageTimings()

        // The heavy work runs on a background actor; doing it inline froze the
        // interface for as long as a 12-megapixel page took.
        let enhanceStart = ContinuousClock.now
        let enhanced = try await renderer.enhance(page, style: style)
        timings.enhanceMs = enhanceStart.duration(to: .now).milliseconds

        let recognizeStart = ContinuousClock.now
        let recognition = try await recognizer.recognize(enhanced.cgImage)
        timings.recognizeMs = recognizeStart.duration(to: .now).milliseconds

        let exportStart = ContinuousClock.now
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString).pdf")
        try exporter.write(
            pages: [.init(image: enhanced.cgImage, recognition: recognition)],
            to: url,
            metadata: .init(title: "Scan")
        )
        timings.exportMs = exportStart.duration(to: .now).milliseconds

        var extraction: String?
        if extractor.isAvailable, !recognition.transcript.isEmpty {
            let extractStart = ContinuousClock.now
            extraction = try? await summarize(recognition)
            timings.extractMs = extractStart.duration(to: .now).milliseconds
        }

        return ScanResult(
            enhanced: enhanced.uiImage,
            recognition: recognition,
            timings: timings,
            pdfURL: url,
            extraction: extraction
        )
    }

    private func summarize(_ recognition: PageRecognition) async throws -> String {
        let kind = try await extractor.classify(recognition)
        let title = try await extractor.suggestTitle(for: recognition)
        guard kind == .receipt || kind == .invoice else {
            return "\(kind.rawValue) — “\(title)”"
        }
        let receipt = try await extractor.extractReceipt(from: recognition)
        let total = receipt.total.map { String(format: "%.2f", $0) } ?? "—"
        return "\(kind.rawValue) — “\(title)”\n\(receipt.vendor ?? "unknown vendor") · \(receipt.date ?? "no date") · \(receipt.currency ?? "") \(total)"
    }
}

enum PipelineError: Error, CustomStringConvertible {
    case noBitmap
    var description: String { "That image had no bitmap to work on." }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
