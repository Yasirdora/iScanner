import Testing
import Foundation
import CoreGraphics
import PDFKit
import ScanCore
import ScanExport

// The single-page text layer is covered in EngineTests. These cover what a
// multi-page scan adds: page order, metadata, page size, and search across
// pages — what a user does with the file once it leaves the app.

/// A temporary PDF location, removed by the caller.
private func temporaryPDF() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("scanengine-\(UUID().uuidString).pdf")
}

/// One page whose only text is `line`, placed in the upper half.
private func page(saying line: String, width: Int = 850, height: Int = 1100) -> SearchablePDFBuilder.Page {
    let run = TextRun(text: line, boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.6, height: 0.03), confidence: 1)
    return .init(image: gradientImage(width: width, height: height), recognition: PageRecognition(runs: [run]))
}

@Test("Several pages come out as several pages, in order")
func pagesKeepTheirOrder() throws {
    let url = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: url) }
    let lines = ["FIRST PAGE ALPHA", "SECOND PAGE BRAVO", "THIRD PAGE CHARLIE"]

    try SearchablePDFBuilder().write(pages: lines.map { page(saying: $0) }, to: url)

    let document = try #require(PDFDocument(url: url))
    #expect(document.pageCount == lines.count)
    for (index, line) in lines.enumerated() {
        let text = try #require(document.page(at: index)?.string)
        #expect(text.contains(line), "page \(index + 1) read: \(text)")
    }
}

@Test("Title and author are written into the PDF")
func metadataIsWritten() throws {
    let url = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [page(saying: "RECEIPT")],
        to: url,
        metadata: .init(title: "Northgate receipt", author: "Scanner")
    )

    let attributes = try #require(PDFDocument(url: url)?.documentAttributes)
    #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Northgate receipt")
    #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "Scanner")
}

@Test("Page size follows the image and the capture resolution")
func pageSizeFollowsResolution() throws {
    // 1700 × 2200 pixels at 200 dpi is 8.5 × 11 inches: US Letter, 612 × 792 pt.
    let url = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [page(saying: "LETTER", width: 1700, height: 2200)],
        to: url,
        metadata: .init(dpi: 200)
    )

    let box = try #require(PDFDocument(url: url)?.page(at: 0)?.bounds(for: .mediaBox))
    #expect(abs(box.width - 612) < 0.5)
    #expect(abs(box.height - 792) < 0.5)
}

@Test("Search finds a word on the page it was printed on")
func searchLandsOnTheRightPage() throws {
    let url = temporaryPDF()
    defer { try? FileManager.default.removeItem(at: url) }

    try SearchablePDFBuilder().write(
        pages: [page(saying: "INVOICE 1001"), page(saying: "PAYMENT DUE 30 DAYS"), page(saying: "THANK YOU")],
        to: url
    )

    let document = try #require(PDFDocument(url: url))
    let matches = document.findString("PAYMENT", withOptions: .caseInsensitive)
    #expect(matches.count == 1)
    let foundOn = try #require(matches.first?.pages.first)
    #expect(document.index(for: foundOn) == 1)
}

@Test("Writing into a folder that does not exist fails with a clear error")
func missingFolderIsAnError() {
    let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/scan.pdf")
    #expect(throws: ExportError.self) {
        try SearchablePDFBuilder().write(pages: [page(saying: "LOST")], to: url)
    }
    #expect(ExportError.cannotWrite(url).description.contains(url.path))
}
