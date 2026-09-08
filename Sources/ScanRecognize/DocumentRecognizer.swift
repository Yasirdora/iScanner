import Foundation
import CoreGraphics
import Vision
import DataDetection
import ScanCore

/// Reads an enhanced page with Vision's structured document recogniser.
///
/// This uses `RecognizeDocumentsRequest` rather than `RecognizeTextRequest`.
/// The older request returns a flat list of lines; this one returns the page's
/// structure — paragraphs, tables with real row and column ranges, lists, and
/// barcodes — plus data detection over the recognised text. Rebuilding a table
/// from loose line boxes is guesswork, so taking Vision's own grouping is both
/// less code and more accurate.
public struct DocumentRecognizer: Sendable {

    public struct Options: Sendable {
        /// Terms the recogniser should favour: part numbers, vendor names, or
        /// jargon that language correction would otherwise "fix" into nonsense.
        public var customWords: [String]
        /// Explicit languages. Empty means detect automatically.
        public var languages: [Locale.Language]
        public var useLanguageCorrection: Bool
        public var detectBarcodes: Bool

        public init(
            customWords: [String] = [],
            languages: [Locale.Language] = [],
            useLanguageCorrection: Bool = true,
            detectBarcodes: Bool = true
        ) {
            self.customWords = customWords
            self.languages = languages
            self.useLanguageCorrection = useLanguageCorrection
            self.detectBarcodes = detectBarcodes
        }

        public static let `default` = Options()
    }

    public init() {}

    public func recognize(_ image: CGImage, options: Options = .default) async throws -> PageRecognition {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = options.useLanguageCorrection
        request.textRecognitionOptions.customWords = options.customWords
        request.barcodeDetectionOptions.enabled = options.detectBarcodes
        if options.languages.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.automaticallyDetectLanguage = false
            request.textRecognitionOptions.recognitionLanguages = options.languages
        }

        let observations = try await request.perform(on: image)
        guard let document = observations.first?.document else {
            return PageRecognition()
        }

        let transcript = document.text.transcript
        return PageRecognition(
            transcript: transcript,
            runs: textRuns(in: document),
            tables: document.tables.map(convert),
            detected: document.text.detectedData.compactMap(convert) + payments(in: transcript),
            barcodes: document.barcodes.compactMap(\.payloadString)
        )
    }

    // MARK: - Conversion

    /// Flattens the document's line observations into positioned runs.
    ///
    /// Lines, not words: the PDF text layer wants runs long enough that a
    /// double-click selects a phrase, and Vision does not emit word boxes for
    /// CJK scripts at all, so lines are the one granularity always available.
    private func textRuns(in container: DocumentObservation.Container) -> [TextRun] {
        container.text.lines.map { line in
            TextRun(
                text: line.transcript,
                boundingBox: boundingBox(of: line),
                confidence: line.confidence
            )
        }
    }

    private func convert(_ table: DocumentObservation.Container.Table) -> RecognizedTable {
        let rows = table.rows.map { row in
            row.map { $0.content.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        // The table's own region is a contour; union of its cells' line boxes is
        // simpler and sufficient for layout purposes.
        let cellBoxes = table.rows.flatMap { $0 }.flatMap { $0.content.text.lines.map(boundingBox) }
        return RecognizedTable(rows: rows, boundingBox: union(cellBoxes))
    }

    private func convert(_ match: DocumentObservation.Container.DataDetectorMatch) -> DetectedValue? {
        switch match.match.details {
        case .emailAddress(let email):
            .init(kind: .email, value: email.emailAddress)
        case .phoneNumber(let phone):
            .init(kind: .phoneNumber, value: phone.phoneNumber)
        case .link(let link):
            .init(kind: .url, value: link.url.absoluteString)
        case .postalAddress(let address):
            .init(kind: .postalAddress, value: address.fullAddress)
        case .calendarEvent(let event):
            event.startDate.map {
                .init(kind: .calendarEvent, value: ISO8601DateFormatter().string(from: $0))
            }
        case .moneyAmount(let money):
            // Two decimals, always: the detector's amount is a Decimal made
            // from a binary floating-point value, and printed as it is,
            // 563,94 € reads back as "563.9400000000001024".
            .init(kind: .money, value: "\(money.currency.identifier) \(money.amount.formatted(Self.amountFormat))")
        case .measurement(let measurement):
            .init(kind: .measurement, value: "\(measurement.value)")
        case .flightNumber(let flight):
            .init(kind: .flightNumber, value: "\(flight.airlineCode)\(flight.flightNumber)")
        case .shipmentTrackingNumber(let shipment):
            .init(kind: .shipmentTracking, value: "\(shipment.carrier) \(shipment.trackingNumber)")
        case .paymentIdentifier(let payment):
            .init(kind: .paymentIdentifier, value: payment.identifier)
        @unknown default:
            nil
        }
    }

    private static let amountFormat = Decimal.FormatStyle(locale: Locale(identifier: "en_US_POSIX"))
        .precision(.fractionLength(2))
        .grouping(.never)

    /// IBANs with valid check digits, which Vision's data detection does not
    /// report. See `IBAN`.
    private func payments(in transcript: String) -> [DetectedValue] {
        IBAN.find(in: transcript).map { DetectedValue(kind: .paymentIdentifier, value: $0) }
    }

    // MARK: - Geometry

    /// Axis-aligned bounds of an observation's corner quad, in Vision's
    /// normalised lower-left space.
    ///
    /// The quad is kept by Vision because text can be rotated; we collapse it
    /// to a rect here. Rotation is preserved separately by the PDF exporter,
    /// which reads the same corners.
    private func boundingBox(of observation: RecognizedTextObservation) -> CGRect {
        let xs = [observation.topLeft.x, observation.topRight.x,
                  observation.bottomLeft.x, observation.bottomRight.x]
        let ys = [observation.topLeft.y, observation.topRight.y,
                  observation.bottomLeft.y, observation.bottomRight.y]
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func union(_ rects: [CGRect]) -> CGRect {
        guard var result = rects.first else { return .zero }
        for rect in rects.dropFirst() { result = result.union(rect) }
        return result
    }
}
