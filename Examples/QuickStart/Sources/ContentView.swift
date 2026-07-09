import SwiftUI
import PhotosUI
import ImageIO
import ScanEngine

struct ContentView: View {
    @State private var selection: PhotosPickerItem?
    @State private var isFlatPage = false
    @State private var isScanning = false
    @State private var page: ScannedPage?
    @State private var pdf: URL?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhotosPicker("Choose a photo of a page", selection: $selection, matching: .images)
                    Toggle("The image is already a flat page", isOn: $isFlatPage)
                } footer: {
                    Text("Turn this on for screenshots and scans, where the page fills the whole image.")
                }

                if isScanning {
                    ProgressView("Scanning…")
                }

                if let page {
                    Section("Page") {
                        Image(decorative: page.image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 320)
                        LabeledContent("Style", value: page.style.title)
                        LabeledContent("Page found", value: page.wasPageFound ? "Yes" : "No")
                    }
                    Section("Text") {
                        Text(page.text.isEmpty ? "No text found." : page.text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                    }
                    if let pdf {
                        ShareLink("Share the searchable PDF", item: pdf)
                    }
                }

                if let failure {
                    Text(failure).foregroundStyle(.red)
                }
            }
            .navigationTitle("QuickStart")
            .onChange(of: selection) {
                Task { await scan() }
            }
        }
    }

    /// Everything the example exists to show: one call to scan, one to export.
    private func scan() async {
        guard let selection else { return }
        isScanning = true
        failure = nil
        defer { isScanning = false }

        do {
            guard let data = try await selection.loadTransferable(type: Data.self),
                  let photo = uprightImage(from: data) else {
                failure = "Could not read that photo."
                return
            }
            let scanner = DocumentScanner(options: .init(findsPage: !isFlatPage))
            let scanned = try await scanner.scan(photo)

            let url = URL.temporaryDirectory.appending(path: "Scan.pdf")
            try scanner.exportPDF([scanned], to: url, title: "Scan")
            page = scanned
            pdf = url
        } catch {
            failure = String(describing: error)
        }
    }

    /// Decodes a photo the right way up. Camera photos store their rotation
    /// as metadata, and a plain decode ignores it, so a portrait page would
    /// reach the scanner lying on its side.
    private func uprightImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4032,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
