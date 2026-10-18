import Testing
import Foundation
import CoreGraphics
import ScanEngine

// A German bill: umlauts, ß, the euro sign, decimal commas, a VAT line, an IBAN
// and a payment reference. The pages come from `scanlab synth --document
// invoice`; every name and number on them is a sample value.
//
// Vision reads an invoice's item table column by column — all descriptions,
// then all amounts — so a character-by-character error rate would punish the
// reading order rather than the reading. These tests count the words that were
// read, in any order, and check the fields a bill is scanned for.

/// Share of the transcript's words that appear in `recognized`, in any order.
func wordsRead(_ recognized: String, of truth: String) -> Double {
    var available: [Substring: Int] = [:]
    for word in recognized.split(whereSeparator: \.isWhitespace) { available[word, default: 0] += 1 }
    let words = truth.split(whereSeparator: \.isWhitespace)
    var read = 0
    for word in words where available[word, default: 0] > 0 {
        available[word, default: 0] -= 1
        read += 1
    }
    return Double(read) / Double(words.count)
}

/// German set as the recognition language, as a caller who knows it should.
private func germanScanner(findsPage: Bool) -> DocumentScanner {
    var options = DocumentScanner.Options(findsPage: findsPage)
    options.recognition.languages = [Locale.Language(identifier: "de-DE")]
    return DocumentScanner(options: options)
}

@Test("Each German invoice is read word for word, flat or photographed", .needsVision,
      arguments: [("invoice", false, 0.971), ("invoice-clean", false, 0.957),
                  ("invoice-hard", false, 0.971), ("invoice-photo", true, 0.971)])
func invoiceWordsAreRead(_ name: String, _ findsPage: Bool, _ measured: Double) async throws {
    // Measured with Xcode 27.0; the limit allows two words fewer.
    let page = try await germanScanner(findsPage: findsPage).scan(try knownPage(name))
    let share = wordsRead(page.text, of: try knownTranscript("invoice"))
    #expect(share >= measured - 0.03, "\(name): \(share) of the words read")
}

@Test("Umlauts, ß and the euro sign come through", .needsVision)
func germanCharactersSurvive() async throws {
    let text = try await germanScanner(findsPage: false).scan(try knownPage("invoice-clean")).text
    for word in ["Musterstraße", "Beispielhausen", "zzgl.", "563,94 €", "Leistungsdatum:"] {
        #expect(text.contains(word), "'\(word)' missing from: \(text)")
    }
}

@Test("The total, the invoice date and the IBAN are found as data", .needsVision)
func billFieldsAreDetected() async throws {
    let detected = try await germanScanner(findsPage: true).scan(try knownPage("invoice-photo")).recognition.detected
    #expect(detected.contains(DetectedValue(kind: .money, value: "EUR 563.94")), "found: \(detected)")
    #expect(detected.contains(DetectedValue(kind: .paymentIdentifier, value: "DE89 3704 0044 0532 0130 00")),
            "found: \(detected)")
    #expect(detected.contains { $0.kind == .calendarEvent && $0.value.hasPrefix("2026-10-14") }, "found: \(detected)")
}

@Test("Every amount is reported with two decimals", .needsVision)
func amountsHaveTwoDecimals() async throws {
    // Regression: the detector's amount is a Decimal made from a binary
    // floating-point value, and printed as it was, 563,94 € came back as
    // "EUR 563.9400000000001024".
    let detected = try await germanScanner(findsPage: true).scan(try knownPage("invoice-photo")).recognition.detected
    let amounts = detected.filter { $0.kind == .money }
    #expect(amounts.count >= 5, "found: \(amounts)")
    for amount in amounts {
        #expect(amount.value.wholeMatch(of: /[A-Z]{3} [0-9]+\.[0-9]{2}/) != nil, "'\(amount.value)'")
    }
}

@Test("With automatic language detection, the euro sign on a photographed bill stays a euro sign", .needsVision)
func euroSurvivesAutomaticLanguage() async throws {
    // This was a known issue. With the language left to automatic detection,
    // Vision read the photographed bill's € as "も", a Japanese character,
    // while the page finder cut the bill close to its print: 4 of the 6 € came
    // through. Cut along the bill's own outline, all 6 do. German set still
    // reads more of the words, so callers who know the language should set it.
    let text = try await DocumentScanner().scan(try knownPage("invoice-photo")).text
    #expect(!text.contains("も"), "read: \(text)")
    #expect(text.filter { $0 == "€" }.count == 6, "read: \(text)")
}

@Test("A quantity printed next to an amount stays out of the amount", .needsVision)
func quantityStaysOutOfTheAmount() async throws {
    // Known issue in Vision's data detection, kept visible. On the flat bill,
    // "4  340,00 €" is grouped as one line and detected as 4340 €, as if the
    // space were a thousands separator. The transcript itself is right; it is
    // the detected amount that is wrong.
    await withKnownIssue("Data detection reads a quantity and an amount as one number") {
        let detected = try await germanScanner(findsPage: false).scan(try knownPage("invoice")).recognition.detected
        #expect(!detected.contains(DetectedValue(kind: .money, value: "EUR 4340.00")), "found: \(detected)")
    }
}
