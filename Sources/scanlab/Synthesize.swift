import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText

// Generates a synthetic "photo of a document": known text, printed cleanly,
// then darkened by a lighting gradient and a soft shadow of the kind a hand or
// phone casts over a page.
//
// A synthetic fixture is worth having because the ground truth is exact. Real
// photographs need transcription by hand before they can score anything, and
// until a real corpus exists this gives the harness something to regress
// against from the first commit.

enum Synthesizer {

    /// How punishing the simulated capture is.
    ///
    /// `normal` is a well-lit handheld photo. `hard` is the case that actually
    /// separates pipelines: a deep lighting falloff that crushes one corner
    /// toward black, a heavy cast shadow, faded ink, and the softness of a
    /// camera that focused slightly short.
    enum Difficulty: String, CaseIterable {
        /// A page as VisionKit hands it back: already cropped, rectified and
        /// colour-corrected, so the lighting is close to flat and the paper is
        /// a light warm grey rather than a shadowed mess. This is the input the
        /// app actually sees, and a pipeline tuned only on raw camera captures
        /// has almost nothing left to do to it.
        case clean
        case normal
        case hard
        /// Clean lighting plus printed colour: a letterhead rule, a
        /// highlighter, and a stamp.
        ///
        /// Kept separate from the accuracy fixtures on purpose. Colour marks
        /// sit on top of text, which costs recognition a little no matter how
        /// good the filter is, so mixing them into the pages that measure
        /// character error rate would put a permanent floor under every reading
        /// and hide real regressions underneath it.
        case colour
        /// Handwritten notes on ruled paper: thin strokes of varying pressure,
        /// in pencil and two ink colours, on a page whose printed rules are
        /// themselves faint. Printed text is dense and uniformly dark;
        /// handwriting is neither, and a tone curve tuned on receipts leaves it
        /// grey.
        case notes

        var hasColour: Bool { self == .colour || self == .notes }
        var isCleanlyLit: Bool { self == .clean || self == .colour }
    }

    /// What is printed on the page.
    enum Document: String, CaseIterable {
        /// An American hardware-store receipt. The original accuracy fixture.
        case receipt
        /// A German invoice ("Rechnung") from a fictional company: umlauts,
        /// ß, the euro sign, decimal commas, a VAT line, an IBAN and a payment
        /// reference — the fields a German bill is scanned for.
        case invoice

        var text: String {
            switch self {
            case .receipt: baseGroundTruth
            case .invoice: invoiceGroundTruth
            }
        }
    }

    /// Roughly a US Letter page at 200 dpi.
    static let pageSize = CGSize(width: 1700, height: 2200)

    /// Text the stamp adds to the page. Kept with the stamp that draws it so
    /// the two cannot drift apart — a fixture whose ground truth omits
    /// something printed on it reports a permanent error rate that looks like a
    /// regression and is only bookkeeping.
    static let stampText = "PAID"

    static func groundTruth(for difficulty: Difficulty, document: Document = .receipt) -> String {
        difficulty.hasColour ? document.text + "\n" + stampText : document.text
    }

    static let baseGroundTruth = """
    NORTHGATE HARDWARE
    1847 Cascade Avenue
    Portland, OR 97214
    (503) 555-0182

    Order #4471-B
    2026-08-14  14:32

    QTY  ITEM                    PRICE
    2    Cedar plank 2x4x8       23.98
    1    Galvanized screws 1lb   14.50
    4    Cabinet hinge brass     31.60
    1    Wood glue 16oz           8.75
    3    Sandpaper 120 grit       9.45

    Subtotal                     88.28
    Tax 8.75%                     7.72
    TOTAL                        96.00

    Paid by card ending 4419
    Returns accepted within 30 days
    """

    /// Every name, number and account here is a sample value: Musterfirma and
    /// Mustermann are the German placeholder names, DE123456789 is the usual
    /// example VAT number, and the IBAN is the example used in banking
    /// documentation. The sums are correct: 473,90 € net plus 19 % is 563,94 €.
    static let invoiceGroundTruth = """
    Musterfirma GmbH
    Musterstraße 12, 12345 Musterstadt
    USt-IdNr. DE123456789

    Max Mustermann
    Beispielweg 3
    54321 Beispielhausen

    RECHNUNG Nr. RE-2026-0815
    Rechnungsdatum: 14.10.2026
    Leistungsdatum: 10.10.2026

    Pos Beschreibung          Menge    Betrag
    1   Beratung (Stunden)        4  340,00 €
    2   Webhosting Jahrespaket    1  129,00 €
    3   Versandpauschale          1    4,90 €

    Nettobetrag                      473,90 €
    zzgl. 19 % USt.                   90,04 €
    Gesamtbetrag                     563,94 €

    Zahlbar bis 28.10.2026 ohne Abzug.
    IBAN: DE89 3704 0044 0532 0130 00
    BIC: COBADEFFXXX
    Verwendungszweck: RE-2026-0815
    """

    static func makePage(
        difficulty: Difficulty = .normal,
        document: Document = .receipt,
        onTable: Bool = false
    ) throws -> CGImage {
        let clean = try renderText(difficulty: difficulty, document: document)
        let page = shade(clean, difficulty: difficulty)
        return onTable ? placeOnTable(page) : page
    }

    // MARK: - Text

    private static func renderText(difficulty: Difficulty, document: Document) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(pageSize.width),
            height: Int(pageSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CLIError.usage }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pageSize))

        // A monospaced face keeps the columns aligned, which also gives the
        // recogniser a real table to find rather than ragged text.
        let font = CTFontCreateWithName("Menlo" as CFString, 44, nil)
        // Faded toner on the hard variant: less ink-to-paper separation for the
        // lighting defect to eat into.
        let inkLevel: CGFloat = switch difficulty {
        case .hard: 0.34
        case .normal: 0.08
        case .clean, .colour, .notes: 0.20
        }
        let black = CGColor(red: inkLevel, green: inkLevel, blue: inkLevel + 0.01, alpha: 1)

        // Colour on the page: a printed letterhead rule, a stamp, and a
        // highlighted line. Every fixture until now was black ink on white
        // paper, which meant the colour filter's whole reason to exist went
        // untested — a pipeline that crushes the page to bitonal scored
        // perfectly against them.
        if difficulty == .notes {
            drawRuledPage(in: context)
            drawHandwriting(in: context)
            guard let page = context.makeImage() else { throw CLIError.usage }
            return page
        }
        if difficulty.hasColour { drawColourElements(in: context) }

        var y = pageSize.height - 220
        for rawLine in document.text.components(separatedBy: "\n") {
            defer { y -= 62 }
            guard !rawLine.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let attributed = NSAttributedString(string: rawLine, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: black,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 180, y: y)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CLIError.usage }
        return image
    }

    /// Marks that a real document carries and a scan must not destroy.
    private static func drawColourElements(_ unused: Void = ()) {}

    private static func drawColourElements(in context: CGContext) {
        // Letterhead rule.
        context.setFillColor(CGColor(red: 0.11, green: 0.31, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 180, y: pageSize.height - 160, width: 1340, height: 12))

        // Highlighter over the total line.
        context.setFillColor(CGColor(red: 0.99, green: 0.90, blue: 0.28, alpha: 1))
        context.fill(CGRect(x: 170, y: pageSize.height - 1394, width: 700, height: 58))

        // A red inspection stamp.
        context.setStrokeColor(CGColor(red: 0.78, green: 0.13, blue: 0.16, alpha: 1))
        context.setLineWidth(9)
        context.strokeEllipse(in: CGRect(x: 1120, y: 300, width: 330, height: 200))
        let stamp = NSAttributedString(string: stampText, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Menlo-Bold" as CFString, 58, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 0.78, green: 0.13, blue: 0.16, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(stamp)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 1200, y: 375)
        CTLineDraw(line, context)
    }

    /// Faint printed rules, as on a notepad.
    private static func drawRuledPage(in context: CGContext) {
        context.setStrokeColor(CGColor(red: 0.62, green: 0.70, blue: 0.82, alpha: 1))
        context.setLineWidth(2)
        for y in stride(from: 120, to: Int(pageSize.height) - 80, by: 74) {
            context.move(to: CGPoint(x: 90, y: Double(y)))
            context.addLine(to: CGPoint(x: pageSize.width - 90, y: Double(y)))
        }
        context.strokePath()
        context.setStrokeColor(CGColor(red: 0.85, green: 0.55, blue: 0.58, alpha: 1))
        context.move(to: CGPoint(x: 240, y: 60))
        context.addLine(to: CGPoint(x: 240, y: pageSize.height - 60))
        context.strokePath()
    }

    /// Strokes standing in for handwriting.
    ///
    /// The point of the fixture is the range: pencil is far lighter than pen,
    /// pressure varies within a single word, and strokes are a third the width
    /// of printed glyph stems. A filter that only handles dense black ink turns
    /// the lighter half of this page to grey.
    private static func drawHandwriting(in context: CGContext) {
        let inks: [(CGColor, CGFloat)] = [
            (CGColor(red: 0.18, green: 0.20, blue: 0.38, alpha: 1), 5),   // blue ballpoint
            (CGColor(red: 0.55, green: 0.18, blue: 0.22, alpha: 1), 4),   // red pen
            (CGColor(red: 0.58, green: 0.58, blue: 0.60, alpha: 1), 3),   // pencil, faint
            (CGColor(red: 0.70, green: 0.70, blue: 0.72, alpha: 1), 2),   // pencil, very faint
        ]
        var line = 0
        for y in stride(from: 180, to: Int(pageSize.height) - 200, by: 74) {
            let (colour, width) = inks[line % inks.count]
            context.setStrokeColor(colour)
            context.setLineWidth(width)
            context.setLineCap(.round)

            var x = 300.0
            while x < pageSize.width - 200 {
                let length = Double.random(in: 26...78)
                let rise = Double.random(in: -22...22)
                context.move(to: CGPoint(x: x, y: Double(y)))
                context.addCurve(
                    to: CGPoint(x: x + length, y: Double(y) + rise),
                    control1: CGPoint(x: x + length * 0.3, y: Double(y) + rise * 2),
                    control2: CGPoint(x: x + length * 0.7, y: Double(y) - rise)
                )
                context.strokePath()
                x += length + Double.random(in: 10...26)
            }
            line += 1
        }
    }

    // MARK: - Scene

    /// The page photographed at an angle on a dark table, covering about half
    /// the frame: what a phone camera actually hands the page finder.
    private static func placeOnTable(_ page: CGImage) -> CGImage {
        let width = 2400.0, height = 3000.0
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let tilt = CIFilter.perspectiveTransform()
        tilt.inputImage = CIImage(cgImage: page)
        tilt.topLeft = CGPoint(x: 0.22 * width, y: 0.84 * height)
        tilt.topRight = CGPoint(x: 0.74 * width, y: 0.80 * height)
        tilt.bottomRight = CGPoint(x: 0.80 * width, y: 0.16 * height)
        tilt.bottomLeft = CGPoint(x: 0.16 * width, y: 0.20 * height)

        // A table lit from one side, darker away from the light.
        let table = CIFilter.linearGradient()
        table.point0 = CGPoint(x: 0, y: height)
        table.point1 = CGPoint(x: width, y: 0)
        table.color0 = CIColor(red: 0.30, green: 0.24, blue: 0.19)
        table.color1 = CIColor(red: 0.13, green: 0.10, blue: 0.08)

        guard let tilted = tilt.outputImage,
              let surface = table.outputImage?.cropped(to: frame) else { return page }
        return CIContext().createCGImage(tilted.composited(over: surface), from: frame) ?? page
    }

    // MARK: - Lighting

    /// Multiplies the clean page by an uneven illumination field.
    ///
    /// This is the exact defect flat-field correction is meant to undo, so a
    /// pipeline that works should recover close to the original text, and the
    /// harness will say by how much.
    private static func shade(_ page: CGImage, difficulty: Difficulty) -> CGImage {
        let source = CIImage(cgImage: page)
        let extent = source.extent
        let hard = difficulty == .hard

        if difficulty.isCleanlyLit {
            // A gentle warm cast and a slight overall lift, which is what a
            // corrected phone scan of white paper actually looks like: not
            // shadowed, but not white either.
            let wash = CIFilter.linearGradient()
            wash.point0 = CGPoint(x: extent.minX, y: extent.maxY)
            wash.point1 = CGPoint(x: extent.maxX, y: extent.minY)
            wash.color0 = CIColor(red: 0.93, green: 0.91, blue: 0.86)
            wash.color1 = CIColor(red: 0.82, green: 0.80, blue: 0.75)
            guard let washImage = wash.outputImage?.cropped(to: extent) else { return page }
            let lit = blend(source, over: washImage, extent: extent)
            return CIContext().createCGImage(lit, from: extent) ?? page
        }

        let falloff = CIFilter.linearGradient()
        falloff.point0 = CGPoint(x: extent.minX, y: extent.maxY)
        falloff.point1 = CGPoint(x: extent.maxX, y: extent.minY)
        falloff.color0 = CIColor(red: 1, green: 1, blue: 0.97)
        falloff.color1 = hard
            ? CIColor(red: 0.16, green: 0.17, blue: 0.22)
            : CIColor(red: 0.42, green: 0.43, blue: 0.47)

        let shadow = CIFilter.radialGradient()
        shadow.center = CGPoint(x: extent.maxX * 0.72, y: extent.maxY * 0.30)
        shadow.radius0 = Float(extent.width * 0.10)
        shadow.radius1 = Float(extent.width * 0.55)
        shadow.color0 = hard
            ? CIColor(red: 0.13, green: 0.14, blue: 0.19)
            : CIColor(red: 0.30, green: 0.31, blue: 0.36)
        shadow.color1 = CIColor(red: 1, green: 1, blue: 1)

        guard let falloffImage = falloff.outputImage?.cropped(to: extent),
              let shadowImage = shadow.outputImage?.cropped(to: extent) else {
            return page
        }

        let field = blend(falloffImage, over: shadowImage, extent: extent)
        var lit = blend(source, over: field, extent: extent)

        if hard {
            // Slight defocus, as from a camera that hunted and settled short.
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = lit.clampedToExtent()
            blur.radius = 1.4
            lit = (blur.outputImage ?? lit).cropped(to: extent)
        }

        let context = CIContext()
        return context.createCGImage(lit, from: extent) ?? page
    }

    private static func blend(_ top: CIImage, over bottom: CIImage, extent: CGRect) -> CIImage {
        let multiply = CIFilter.multiplyBlendMode()
        multiply.inputImage = top
        multiply.backgroundImage = bottom
        return (multiply.outputImage ?? top).cropped(to: extent)
    }
}
