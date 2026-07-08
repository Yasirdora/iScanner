import Testing
import Foundation
import ScanCore
import ScanExtract

// Extraction is the one stage that needs hardware the engine cannot assume:
// the on-device model exists only on Apple Intelligence devices, and not on
// CI runners. These tests pin what happens around the model, so they pass
// the same way with or without it and never call it.

/// The three operations, so each guard is checked on every entry point.
enum ExtractionOperation: String, CaseIterable, Sendable {
    case classify, receipt, title

    func run(on recognition: PageRecognition, with extractor: some DocumentExtracting) async throws {
        switch self {
        case .classify: _ = try await extractor.classify(recognition)
        case .receipt: _ = try await extractor.extractReceipt(from: recognition)
        case .title: _ = try await extractor.suggestTitle(for: recognition)
        }
    }
}

@Test("A page with no text is refused before the model is asked", arguments: ExtractionOperation.allCases)
func blankPageNeverReachesTheModel(_ operation: ExtractionOperation) async throws {
    let extractor = FoundationModelExtractor()
    let blank = PageRecognition(transcript: "  \n ")

    let error = await #expect(throws: ExtractionError.self) {
        try await operation.run(on: blank, with: extractor)
    }
    // With a model there is nothing to send it; without one there is nothing
    // to send it to. Either way the reason has to say which.
    switch error {
    case .emptyDocument?:
        #expect(extractor.isAvailable)
    case .modelUnavailable?:
        #expect(!extractor.isAvailable)
    case nil:
        break  // #expect(throws:) has already recorded the failure.
    }
}

@Test(
    "Without the on-device model, extraction says so instead of guessing",
    .enabled(if: !FoundationModelExtractor().isAvailable, "this machine has the model; CI runners do not"),
    arguments: ExtractionOperation.allCases
)
func missingModelIsReported(_ operation: ExtractionOperation) async throws {
    let extractor = FoundationModelExtractor()

    let page = PageRecognition(transcript: "NORTHGATE HARDWARE\nTOTAL 96.00")
    let error = await #expect(throws: ExtractionError.self) {
        try await operation.run(on: page, with: extractor)
    }
    guard case .modelUnavailable(let reason)? = error else {
        Issue.record("expected modelUnavailable, got \(String(describing: error))")
        return
    }
    #expect(!reason.isEmpty)
}

@Test("Extraction errors explain themselves in words")
func extractionErrorsAreReadable() {
    #expect(ExtractionError.emptyDocument.description.contains("No recognised text"))
    let unavailable = ExtractionError.modelUnavailable("deviceNotEligible").description
    #expect(unavailable.contains("unavailable"))
    #expect(unavailable.contains("deviceNotEligible"))
}

@Test("A receipt survives a JSON round trip, including missing fields")
func receiptRoundTripsThroughJSON() throws {
    // Callers store and send extracted fields; a field the model could not
    // find must come back as absent, not as zero or an empty string.
    let receipt = Receipt(vendor: "Northgate Hardware", date: "2026-08-14", total: 96.00, tax: nil, currency: "USD")
    let decoded = try JSONDecoder().decode(Receipt.self, from: JSONEncoder().encode(receipt))
    #expect(decoded == receipt)
    #expect(decoded.tax == nil)
}
