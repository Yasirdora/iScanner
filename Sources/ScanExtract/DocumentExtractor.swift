import Foundation
import ScanCore

/// Turns a page's raw recognition output into typed fields.
///
/// Callers depend on this protocol rather than on Foundation Models directly.
/// The iOS 26 implementation feeds the OCR transcript to the on-device model as
/// text; the iOS 27 path will hand the model the page image itself alongside
/// Vision's OCR tool. Both satisfy this seam, so nothing above it changes.
public protocol DocumentExtracting: Sendable {
    var isAvailable: Bool { get }
    func classify(_ recognition: PageRecognition) async throws -> DocumentKind
    func extractReceipt(from recognition: PageRecognition) async throws -> Receipt
    func suggestTitle(for recognition: PageRecognition) async throws -> String
}

public enum DocumentKind: String, Sendable, Codable, CaseIterable {
    case receipt, invoice, businessCard, identityDocument, letter, form, notes, other
}

public struct Receipt: Sendable, Codable, Equatable {
    public var vendor: String?
    public var date: String?
    public var total: Double?
    public var tax: Double?
    public var currency: String?

    public init(
        vendor: String? = nil,
        date: String? = nil,
        total: Double? = nil,
        tax: Double? = nil,
        currency: String? = nil
    ) {
        self.vendor = vendor
        self.date = date
        self.total = total
        self.tax = tax
        self.currency = currency
    }
}

public enum ExtractionError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case emptyDocument

    public var description: String {
        switch self {
        case .modelUnavailable(let reason): "On-device model unavailable: \(reason)"
        case .emptyDocument: "No recognised text to extract from."
        }
    }
}
