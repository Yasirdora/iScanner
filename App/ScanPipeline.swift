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
    /// A small copy for grids and rails; the full-resolution page is only
    /// decoded where it is actually read.
    var thumbnail: UIImage
}

/// A page in the session, from the shutter to the share sheet.
///
/// A page exists — and is on screen — before its result does. The raw capture
/// is shown the moment it arrives and the engine runs against it in the
/// background, so nothing ever waits on a blocking spinner, and progress
/// belongs to the page it describes rather than to the whole screen.
struct PageItem: Identifiable {
    enum Stage: Equatable {
        case enhancing
        case recognizing
        case exporting
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    let id = UUID()
    /// The capture, until the enhanced page replaces it.
    var source: UIImage?
    /// Grid-sized copy of the capture, so drawing a 170-point card never holds
    /// a 12-megapixel page in memory.
    let thumbnail: UIImage
    var stage: Stage = .enhancing
    var result: ScanResult?

    init(source: UIImage) {
        self.source = source
        self.thumbnail = downsampled(source, maxDimension: 640)
    }

    /// What the page is called in the grid: the extractor's title when it has
    /// one, a plain description otherwise.
    var title: String {
        guard let line = result?.extraction?.split(separator: "\n").first, !line.isEmpty else {
            return "Scanned page"
        }
        return String(line)
    }

    /// The label under the progress indicator while the page is being worked on.
    var stageLabel: String {
        switch stage {
        case .enhancing: "Enhancing"
        case .recognizing: "Reading text"
        case .exporting: "Building PDF"
        case .ready, .failed: ""
        }
    }
}

/// Runs captured pages through enhance → recognise → export.
@MainActor
@Observable
final class ScanPipeline {
    var style: ScanStyle = .auto
    private(set) var pages: [PageItem] = []

    private let renderer = PageRenderer()
    private let selector = DocumentCandidateSelector()
    private let recognizer = DocumentRecognizer()
    private let exporter = SearchablePDFBuilder()
    private let extractor = FoundationModelExtractor()

    var extractionAvailable: Bool { extractor.isAvailable }

    // MARK: - Capture

    /// Takes pages that arrive finished — already rectified by the system
    /// scanner — and runs each through the engine in turn.
    func run(on images: [UIImage]) async {
        guard !images.isEmpty else { return }
        for image in images {
            let page = PageItem(source: image)
            pages.append(page)
            guard let bitmap = image.cgImage else {
                update(page.id) { $0.stage = .failed(PipelineError.noBitmap.description) }
                continue
            }
            await finish(page.id, page: SendableImage(bitmap))
        }
    }

    /// Runs an imported photo, flattened onto the corners the user confirmed.
    func run(imported image: UIImage, quad: DocumentQuad?) async {
        let page = PageItem(source: image)
        pages.append(page)
        guard let bitmap = image.cgImage else {
            update(page.id) { $0.stage = .failed(PipelineError.noBitmap.description) }
            return
        }
        do {
            let flattened = try await renderer.flatten(SendableImage(bitmap), quad: quad)
            await finish(page.id, page: flattened)
        } catch {
            update(page.id) { $0.stage = .failed(String(describing: error)) }
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

    // MARK: - Session

    func clear() {
        pages.removeAll()
    }

    func remove(_ id: UUID) {
        pages.removeAll { $0.id == id }
    }

    /// Puts a page back where it was, for undoing a delete.
    func insert(_ page: PageItem, at index: Int) {
        pages.insert(page, at: min(index, pages.count))
    }

    /// One searchable PDF for the whole session, for sharing everything at once.
    func exportAllPDF() -> URL? {
        let ready = pages.compactMap(\.result).compactMap { result in
            result.enhanced.cgImage.map { (image: $0, recognition: result.recognition) }
        }
        guard !ready.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scans-\(UUID().uuidString).pdf")
        do {
            try exporter.write(
                pages: ready.map { .init(image: $0.image, recognition: $0.recognition) },
                to: url,
                metadata: .init(title: "Scans")
            )
            return url
        } catch {
            return nil
        }
    }

    // MARK: - The engine run

    private func finish(_ id: UUID, page: SendableImage) async {
        var timings = StageTimings()
        do {
            update(id) { $0.stage = .enhancing }
            let enhanceStart = ContinuousClock.now
            let enhanced = try await renderer.enhance(page, style: style)
            timings.enhanceMs = enhanceStart.duration(to: .now).milliseconds

            update(id) { $0.stage = .recognizing }
            let recognizeStart = ContinuousClock.now
            let recognition = try await recognizer.recognize(enhanced.cgImage)
            timings.recognizeMs = recognizeStart.duration(to: .now).milliseconds

            update(id) { $0.stage = .exporting }
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

            let result = ScanResult(
                enhanced: enhanced.uiImage,
                recognition: recognition,
                timings: timings,
                pdfURL: url,
                extraction: extraction,
                thumbnail: downsampled(enhanced.uiImage, maxDimension: 640)
            )
            update(id) { page in
                page.result = result
                page.stage = .ready
                // The full capture is no longer needed once the enhanced page
                // and its PDF exist; holding it would double the session's
                // memory for nothing.
                page.source = nil
            }
        } catch {
            update(id) { $0.stage = .failed(String(describing: error)) }
        }
    }

    /// Applies a change to the page with this id, if the user has not already
    /// removed it. Every stage reports through here, so a page deleted mid-run
    /// simply stops being updated instead of coming back.
    private func update(_ id: UUID, _ mutate: (inout PageItem) -> Void) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&pages[index])
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

/// A grid- or rail-sized copy of an image, drawn at 1x points: big enough for a
/// card at 3x, small enough that a whole session fits in memory comfortably.
func downsampled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension else { return image }
    let scale = maxDimension / longest
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: target, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }
}
