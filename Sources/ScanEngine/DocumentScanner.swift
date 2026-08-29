import Foundation
import CoreGraphics

// The types in this API come from the stage modules. Re-exporting them means
// `import ScanEngine` is the only import a caller needs for the common path;
// each stage module can still be imported on its own.
@_exported import ScanCore
@_exported import ScanCapture
@_exported import ScanRecognize
import ScanEnhance
import ScanExport

/// The engine in one call: a photo in, a straightened, cleaned page and its
/// text out.
///
/// It runs the stages in the order the app does — find the page, straighten
/// it, clean it up, read it — and `exportPDF(_:to:title:author:)` writes the
/// results as a searchable PDF. Every stage is also its own module, for callers
/// that need to drive one directly.
///
/// ```swift
/// let scanner = DocumentScanner()
/// let page = try await scanner.scan(photo)
/// print(page.text)
/// try scanner.exportPDF([page], to: url, title: "Receipt")
/// ```
///
/// Everything runs on the device. Nothing here touches the network.
public struct DocumentScanner: Sendable {

    public struct Options: Sendable {
        /// How the page should look. `.auto` reads the page and chooses.
        public var style: ScanStyle

        /// Whether to look for the page in the photo and straighten it.
        ///
        /// Turn it off to skip page finding for images that are already a
        /// flat page, such as a screenshot or a file from a flatbed scanner.
        /// With it on, such an image comes back whole when it shows nothing
        /// but the page.
        public var findsPage: Bool

        /// A learned corner detector, offered to the page finder as one more
        /// candidate. The package does not bundle a model; create one with
        /// `CoreMLCornerDetector(model:)`.
        public var cornerModel: (any DocumentCornerPredicting)?

        /// Settings for text recognition: languages, custom words, barcodes.
        public var recognition: DocumentRecognizer.Options

        public init(
            style: ScanStyle = .auto,
            findsPage: Bool = true,
            cornerModel: (any DocumentCornerPredicting)? = nil,
            recognition: DocumentRecognizer.Options = .default
        ) {
            self.style = style
            self.findsPage = findsPage
            self.cornerModel = cornerModel
            self.recognition = recognition
        }
    }

    public var options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    /// Scans one photo.
    ///
    /// When no page is found — or `findsPage` is off — the whole photo is
    /// cleaned and read, and `ScannedPage.outline` is `nil` so the caller can
    /// tell the difference.
    public func scan(_ photo: CGImage) async throws -> ScannedPage {
        var outline: DocumentQuad?
        var flat = photo
        if options.findsPage,
           let found = try await DocumentCandidateSelector(cornerModel: options.cornerModel).best(in: photo) {
            outline = found.quad
            flat = try PerspectiveRectifier().rectify(
                photo,
                topLeft: found.quad.topLeft,
                topRight: found.quad.topRight,
                bottomRight: found.quad.bottomRight,
                bottomLeft: found.quad.bottomLeft
            )
        }

        // Resolve Auto here rather than inside the enhancer, so the page can
        // report which style it was given.
        let enhancer = DocumentEnhancer()
        let style = options.style == .auto ? try enhancer.chooseStyle(for: flat) : options.style
        let cleaned = try enhancer.enhance(flat, style: style, options: .preset(for: style))
        let recognition = try await DocumentRecognizer().recognize(cleaned, options: options.recognition)

        return ScannedPage(image: cleaned, recognition: recognition, outline: outline, style: style)
    }

    /// Writes scanned pages, in order, to one searchable PDF.
    ///
    /// An empty list is refused: the PDF writer underneath would otherwise
    /// produce a file with one blank page, which looks like a scan that lost
    /// its content.
    public func exportPDF(
        _ pages: [ScannedPage],
        to url: URL,
        title: String? = nil,
        author: String? = nil
    ) throws {
        guard !pages.isEmpty else { throw ScanError.noPages }
        try SearchablePDFBuilder().write(
            pages: pages.map { .init(image: $0.image, recognition: $0.recognition) },
            to: url,
            metadata: .init(title: title, author: author)
        )
    }
}

/// Errors from `DocumentScanner` itself. Stage errors pass through unchanged.
public enum ScanError: Error, CustomStringConvertible {
    case noPages

    public var description: String {
        switch self {
        case .noPages: "There are no pages to export."
        }
    }
}
