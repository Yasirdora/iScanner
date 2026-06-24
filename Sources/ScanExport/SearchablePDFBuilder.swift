import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import ScanCore

/// Writes a PDF whose visible layer is the enhanced page image and whose text
/// layer is invisible, positioned, selectable text.
///
/// Two details separate a usable text layer from a cosmetic one:
///
/// 1. The text is drawn in `CGTextDrawingMode.invisible`, which emits the PDF
///    `Tr 3` render mode. Drawing with a transparent fill colour instead — the
///    common shortcut — still emits paint operations, and some viewers and
///    printers render them anyway.
/// 2. Each run's font size and horizontal scale are fitted to its own bounding
///    box, so a selection highlight lands on the ink instead of drifting away
///    from it across the line. A single global font size cannot do this,
///    because Vision's boxes vary in width per line.
public struct SearchablePDFBuilder: Sendable {

    /// Base-14 PDF font: present in every conforming reader, so nothing is
    /// embedded and the text layer costs almost nothing in file size.
    private static let fontName = "Helvetica"

    /// Fraction of a line's box that sits below the baseline. Vision's boxes
    /// span the full glyph extent including descenders; text is drawn from the
    /// baseline, so runs must be lifted by roughly the descender depth.
    private static let descenderFraction: CGFloat = 0.21

    public struct Page: Sendable {
        public var image: CGImage
        public var recognition: PageRecognition

        public init(image: CGImage, recognition: PageRecognition) {
            self.image = image
            self.recognition = recognition
        }
    }

    public struct Metadata: Sendable {
        public var title: String?
        public var author: String?
        /// Assumed capture resolution, used to size pages in points.
        public var dpi: CGFloat

        public init(title: String? = nil, author: String? = nil, dpi: CGFloat = 200) {
            self.title = title
            self.author = author
            self.dpi = dpi
        }

        public static let `default` = Metadata()
    }

    public init() {}

    public func write(pages: [Page], to url: URL, metadata: Metadata = .default) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw ExportError.cannotWrite(url)
        }

        var info: [String: Any] = [:]
        if let title = metadata.title { info[kCGPDFContextTitle as String] = title }
        if let author = metadata.author { info[kCGPDFContextAuthor as String] = author }

        // A media box is required up front but each page supplies its own, so
        // this is only a default for pages that do not.
        var defaultBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &defaultBox, info as CFDictionary) else {
            throw ExportError.cannotWrite(url)
        }

        for page in pages {
            let size = pageSize(for: page.image, dpi: metadata.dpi)
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.draw(page.image, in: box)
            drawTextLayer(page.recognition.runs, in: box, context: context)
            context.endPage()
        }

        context.closePDF()
    }

    // MARK: - Text layer

    private func drawTextLayer(_ runs: [TextRun], in box: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)

        for run in runs {
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Vision normalises to the lower-left origin, which is also PDF's
            // convention, so this is a scale with no flip.
            let rect = CGRect(
                x: run.boundingBox.minX * box.width,
                y: run.boundingBox.minY * box.height,
                width: run.boundingBox.width * box.width,
                height: run.boundingBox.height * box.height
            )
            guard rect.width > 0.5, rect.height > 0.5 else { continue }

            draw(text, fitting: rect, context: context)
        }

        context.restoreGState()
    }

    private func draw(_ text: String, fitting rect: CGRect, context: CGContext) {
        // Fit by choosing the type size, never by stretching the text matrix.
        //
        // Helvetica's advances will not match the scanned typeface, so a run
        // has to be fitted to the ink it stands for or selection highlights
        // drift across the line. Doing that with a horizontal scale works
        // visually and ruins the text: a stretched matrix leaves wide gaps
        // between glyphs and every PDF reader takes those gaps for spaces. A
        // real scan of "INT. COFFEE SHOP" came back out of the file as
        // "I N T . C O F F E E S H O P" — unusable for the one thing this
        // layer exists to allow, which is pasting the words somewhere else.
        //
        // Sizing the font so its natural width already equals the box leaves
        // the advances untouched, so the text extracts as it was written.
        guard let size = fontSize(fitting: text, toWidth: rect.width) else { return }

        // Core Text's attribute name rather than UIKit's, so this target
        // builds for macOS as well and the harness can run on the desktop.
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key:
                CTFontCreateWithName(Self.fontName as CFString, size, nil)]
        ))

        var matrix = CGAffineTransform.identity
        matrix.tx = rect.minX
        matrix.ty = rect.minY + rect.height * Self.descenderFraction

        context.textMatrix = matrix
        CTLineDraw(line, context)
    }

    /// The type size at which a string's natural width matches `width`.
    ///
    /// Measured once at a reference size and scaled: type advances are linear
    /// in point size, so a single measurement is exact.
    private func fontSize(fitting text: String, toWidth width: CGFloat) -> CGFloat? {
        let reference: CGFloat = 100
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key:
                CTFontCreateWithName(Self.fontName as CFString, reference, nil)]
        ))
        let naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard naturalWidth > 0 else { return nil }
        return reference * width / CGFloat(naturalWidth)
    }

    private func pageSize(for image: CGImage, dpi: CGFloat) -> CGSize {
        let scale = 72.0 / max(dpi, 1)
        return CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case cannotWrite(URL)

    public var description: String {
        switch self {
        case .cannotWrite(let url): "Could not open \(url.path) for writing."
        }
    }
}
