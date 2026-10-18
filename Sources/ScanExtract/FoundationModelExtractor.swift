import Foundation
import FoundationModels
import ScanCore

/// `DocumentExtracting` backed by Apple's on-device foundation model.
///
/// Nothing here is sent anywhere. The model that ships with Apple Intelligence
/// runs on the Neural Engine, so extraction costs no network round trip, no API
/// key, and no per-scan fee — which is what makes it viable to give away for
/// free what competitors gate behind a subscription.
public struct FoundationModelExtractor: DocumentExtracting {

    /// The on-device model's context is a few thousand tokens shared between
    /// instructions, prompt, and response. A dense page of OCR can exceed that
    /// on its own, so transcripts are clipped. Receipts and cards put their
    /// identifying fields near the top, so a head-clip loses least.
    private static let transcriptCharacterLimit = 6_000

    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    private func requireModel() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw ExtractionError.modelUnavailable(String(describing: reason))
        @unknown default:
            throw ExtractionError.modelUnavailable("unknown")
        }
    }

    /// Extraction is a parsing task, not a creative one: the same page must
    /// always yield the same fields, so sampling is disabled.
    private var deterministic: GenerationOptions {
        GenerationOptions(samplingMode: .greedy)
    }

    private func clipped(_ recognition: PageRecognition) throws -> String {
        let text = recognition.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ExtractionError.emptyDocument }
        return String(text.prefix(Self.transcriptCharacterLimit))
    }

    // MARK: - Operations

    public func classify(_ recognition: PageRecognition) async throws -> DocumentKind {
        try requireModel()
        let text = try clipped(recognition)

        let session = LanguageModelSession {
            "You classify scanned documents by their type."
            "Answer only with the single best-fitting category."
        }
        let response = try await session.respond(
            to: "Classify this scanned page:\n\n\(text)",
            generating: GeneratedKind.self,
            options: deterministic
        )
        return DocumentKind(rawValue: response.content.kind.rawValue) ?? .other
    }

    public func extractReceipt(from recognition: PageRecognition) async throws -> Receipt {
        try requireModel()
        let text = try clipped(recognition)

        // Vision's data detectors already resolved money amounts and dates with
        // locale-aware parsers. Passing those alongside the raw text gives the
        // model verified candidates to choose between rather than asking it to
        // parse numerals itself, which is where small models make mistakes.
        let hints = recognition.detected
            .filter { $0.kind == .money || $0.kind == .calendarEvent }
            .map { "\($0.kind.rawValue): \($0.value)" }
            .joined(separator: "\n")

        let session = LanguageModelSession {
            "You extract structured fields from receipts and invoices."
            "Use only values that appear in the provided text."
            "If a field is absent or illegible, leave it empty rather than guessing."
        }

        let prompt = hints.isEmpty
            ? "Receipt text:\n\n\(text)"
            : "Receipt text:\n\n\(text)\n\nValues already parsed from the page:\n\(hints)"

        let response = try await session.respond(
            to: prompt,
            generating: GeneratedReceipt.self,
            options: deterministic
        )
        let generated = response.content
        return Receipt(
            vendor: generated.vendor.nilIfBlank,
            date: generated.date.nilIfBlank,
            total: generated.total,
            tax: generated.tax,
            currency: generated.currency.nilIfBlank
        )
    }

    public func suggestTitle(for recognition: PageRecognition) async throws -> String {
        try requireModel()
        let text = try clipped(recognition)

        let session = LanguageModelSession {
            "You name scanned documents for a filing system."
            "Titles are short, specific, and contain no file extension or date prefix."
        }
        let response = try await session.respond(
            to: "Suggest a filename-safe title for this page:\n\n\(text)",
            generating: GeneratedTitle.self,
            options: deterministic
        )
        return response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Generable schemas

/// Guided generation constrains decoding to the schema, so these come back as
/// valid values by construction — there is no JSON string to parse and no
/// malformed-output branch to handle.

@Generable
private enum GeneratedDocumentKind: String {
    case receipt, invoice, businessCard, identityDocument, letter, form, notes, other
}

@Generable
private struct GeneratedKind {
    @Guide(description: "The category that best describes the page.")
    var kind: GeneratedDocumentKind
}

@Generable
private struct GeneratedReceipt {
    @Guide(description: "Merchant or business name exactly as printed. Empty if absent.")
    var vendor: String

    @Guide(description: "Transaction date in ISO 8601 (YYYY-MM-DD). Empty if absent.")
    var date: String

    @Guide(description: "Grand total actually charged, as a number without a currency symbol.")
    var total: Double?

    @Guide(description: "Tax charged, as a number without a currency symbol.")
    var tax: Double?

    @Guide(description: "ISO 4217 currency code, such as USD or EUR. Empty if not stated.")
    var currency: String
}

@Generable
private struct GeneratedTitle {
    @Guide(description: "A concise title of at most six words.")
    var title: String
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
