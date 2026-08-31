import Testing
import Foundation
import CoreGraphics
import ScanCore
import ScanRecognize

// What the recogniser hands to the rest of the engine: text in reading order,
// line boxes the PDF layer can trust, and the structured data Vision finds.
// All read from the clean receipt, whose exact layout is known.

private func readCleanReceipt() async throws -> PageRecognition {
    try await DocumentRecognizer().recognize(try knownPage("receipt-clean"))
}

@Test("Lines come out in reading order, top to bottom", .needsVision)
func linesFollowReadingOrder() async throws {
    let reading = try await readCleanReceipt()
    #expect(reading.runs.count >= 20)

    // Within a row (item, then price) boxes may sit a hair apart, so a line
    // may start up to 0.01 of the page higher than the one before it.
    for (previous, next) in zip(reading.runs, reading.runs.dropFirst()) {
        #expect(next.boundingBox.midY <= previous.boundingBox.midY + 0.01,
                "'\(next.text)' came after '\(previous.text)' but sits higher")
    }

    // The transcript tells the same story.
    let transcript = reading.transcript
    let landmarks = ["NORTHGATE HARDWARE", "Order", "Subtotal", "TOTAL", "Returns accepted"]
    let positions = try landmarks.map { landmark in
        try #require(transcript.range(of: landmark), "'\(landmark)' missing from the transcript").lowerBound
    }
    #expect(positions == positions.sorted(), "landmarks out of order in: \(transcript)")
}

@Test("Every line box lies inside the page", .needsVision)
func boxesStayOnThePage() async throws {
    let reading = try await readCleanReceipt()
    let page = CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.001, dy: -0.001)
    for run in reading.runs {
        #expect(page.contains(run.boundingBox), "'\(run.text)' at \(run.boundingBox)")
        #expect(run.boundingBox.width > 0 && run.boundingBox.height > 0, "'\(run.text)' has no area")
        #expect((0...1).contains(run.confidence), "'\(run.text)' confidence \(run.confidence)")
    }
}

@Test("Line boxes sit where the text is printed", .needsVision)
func boxesMatchThePrintedLayout() async throws {
    // Lower-left origin, as Vision and PDF use it: the heading is near the
    // top of the page, the total a little below the middle.
    let reading = try await readCleanReceipt()
    let heading = try #require(reading.runs.first { $0.text.contains("NORTHGATE") })
    let total = try #require(reading.runs.first { $0.text == "TOTAL" })

    #expect(abs(heading.boundingBox.midY - 0.905) < 0.03, "heading at \(heading.boundingBox.midY)")
    #expect(abs(total.boundingBox.midY - 0.427) < 0.03, "total at \(total.boundingBox.midY)")
    #expect(abs(heading.boundingBox.minX - total.boundingBox.minX) < 0.01, "left margin is not shared")
}

@Test("A blank page reads as no text at all", .needsVision)
func blankPageHasNoText() async throws {
    let context = try #require(CGContext(
        data: nil, width: 600, height: 800,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))

    let reading = try await DocumentRecognizer().recognize(try #require(context.makeImage()))
    #expect(reading.transcript.isEmpty)
    #expect(reading.runs.isEmpty)
}

@Test("Reading the same page twice gives the same result", .needsVision)
func recognitionIsRepeatable() async throws {
    // The accuracy limits assume this. If Vision ever stops being repeatable,
    // this fails first and says why the others became flaky.
    let first = try await readCleanReceipt()
    let second = try await readCleanReceipt()
    #expect(first == second)
}

@Test("The phone number and the address are found as data, not just text", .needsVision)
func structuredDataIsDetected() async throws {
    let detected = try await readCleanReceipt().detected
    #expect(detected.contains(DetectedValue(kind: .phoneNumber, value: "(503) 555-0182")), "found: \(detected)")
    #expect(detected.contains { $0.kind == .postalAddress && $0.value.contains("1847 Cascade Avenue") },
            "found: \(detected)")
}

@Test("The item list is found as a table, with its prices in it", .needsVision)
func itemListIsATable() async throws {
    let tables = try await readCleanReceipt().tables
    let cells = tables.flatMap { $0.rows.flatMap { $0 } }
    #expect(!tables.isEmpty)
    #expect(cells.contains { $0.contains("23.98") } && cells.contains { $0.contains("31.60") }, "cells: \(cells)")
}
