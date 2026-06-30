import PhotosUI
import ScanCapture
import ScanCore
import SwiftUI

/// The app's only screen: the pages captured so far, and the ways to add one.
struct ScanView: View {
    @State private var pipeline = ScanPipeline()
    @State private var destination: Destination?
    @State private var photoItem: PhotosPickerItem?
    @State private var isFindingPage = false

    /// Every full-screen flow this view can present.
    ///
    /// One enum and one `fullScreenCover`, not one modifier per flow. SwiftUI
    /// keeps a single presentation of each kind per view, so stacking several
    /// `fullScreenCover` modifiers leaves all but one silently dead — which is
    /// exactly what happened when a third capture path was added and its button
    /// did nothing at all.
    private enum Destination: Identifiable {
        /// Apple's scanner, for a page that fills the frame.
        case documentScanner
        /// Plain shutter with live detection, for a small item on a larger surface.
        case itemCamera
        /// Confirming the detected edges of a photo before it is processed.
        case adjustEdges(image: UIImage, quad: DocumentQuad?)
        /// Reading a finished page full screen, with Live Text.
        case viewPage(index: Int)

        var id: String {
            switch self {
            case .documentScanner: "documentScanner"
            case .itemCamera: "itemCamera"
            case .adjustEdges: "adjustEdges"
            case .viewPage: "viewPage"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                styleSection
                if let failure = pipeline.failure { failureSection(failure) }
                ForEach(Array(pipeline.results.enumerated()), id: \.element.id) { index, result in
                    ResultCard(result: result) { destination = .viewPage(index: index) }
                }
                if pipeline.results.isEmpty && !isBusy {
                    emptySection
                }
            }
            .navigationTitle("Scanner")
            .toolbar { toolbar }
            .overlay { busyOverlay }
            .fullScreenCover(item: $destination, content: cover)
            .onChange(of: photoItem, handlePhotoSelection)
        }
    }

    private var isBusy: Bool { pipeline.isRunning || isFindingPage }

    // MARK: - Sections

    private var styleSection: some View {
        Section {
            Picker("Style", selection: $pipeline.style) {
                ForEach(ScanStyle.offered, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        } footer: {
            Text(pipeline.extractionAvailable
                 ? "On-device model available — pages will also be classified and named."
                 : "On-device model unavailable on this device. Capture, enhancement, recognition, and PDF export are unaffected.")
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var emptySection: some View {
        Section {
            ContentUnavailableView(
                "No scans yet",
                systemImage: "doc.viewfinder",
                description: Text("Scan a page or pick a photo. Everything is processed on this device.")
            )
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Clear", action: pipeline.clear)
                .disabled(pipeline.results.isEmpty)
        }
        ToolbarItemGroup(placement: .bottomBar) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Photo", systemImage: "photo")
            }
            Spacer()
            // Two capture paths, because one detector cannot cover both jobs.
            // Apple's scanner is fast and familiar and finds a page that fills
            // the frame. It returns nothing at all for a small card lying on a
            // larger sheet — measured on real photographs — and cannot be
            // tuned, so that case gets a path of its own.
            Button {
                destination = .itemCamera
            } label: {
                Label("Small item", systemImage: "viewfinder.rectangular")
            }
            Spacer()
            Button {
                destination = .documentScanner
            } label: {
                Label("Scan", systemImage: "doc.viewfinder")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if isFindingPage {
            ProgressView("Finding the page").controlSize(.large)
        } else if pipeline.isRunning {
            ProgressView("Processing").controlSize(.large)
        }
    }

    // MARK: - Presentation

    @ViewBuilder
    private func cover(for destination: Destination) -> some View {
        switch destination {
        case .documentScanner:
            DocumentCamera { images in
                self.destination = nil
                Task { await pipeline.run(on: images) }
            }
            .ignoresSafeArea()

        case .itemCamera:
            ShutterCameraView(
                onCancel: { self.destination = nil },
                onCapture: { image in Task { await findPage(in: image) } }
            )

        case .viewPage(let index):
            PageViewerScreen(
                results: pipeline.results,
                selection: index,
                onDone: { self.destination = nil }
            )

        case .adjustEdges(let image, let quad):
            CropEditor(
                image: image,
                quad: quad,
                onCancel: { self.destination = nil },
                onApply: { corrected in
                    self.destination = nil
                    Task { await pipeline.run(imported: image, quad: corrected) }
                }
            )
        }
    }

    // MARK: - Flows

    /// An imported or hand-shot photo is a whole picture, not a page: the
    /// document sits somewhere inside it. Detection is reliable about *which*
    /// object is the page and only approximate about its edge, so the corners
    /// are always offered rather than applied silently.
    private func findPage(in image: UIImage) async {
        isFindingPage = true
        let quad = await pipeline.findDocument(in: image)
        isFindingPage = false
        destination = .adjustEdges(image: image, quad: quad)
    }

    private func handlePhotoSelection(_ previous: PhotosPickerItem?, _ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await findPage(in: image)
        }
    }
}

// MARK: - Result

private struct ResultCard: View {
    let result: ScanResult
    var onOpen: () -> Void

    var body: some View {
        Section {
            Button(action: onOpen) {
                Image(uiImage: result.enhanced)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 340)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets())

            LabeledContent("Characters", value: "\(result.recognition.transcript.count)")
            LabeledContent("Text runs", value: "\(result.recognition.runs.count)")
            if !result.recognition.tables.isEmpty {
                LabeledContent("Tables", value: "\(result.recognition.tables.count)")
            }
            if !result.recognition.detected.isEmpty {
                LabeledContent("Detected values", value: "\(result.recognition.detected.count)")
            }
            if !result.recognition.barcodes.isEmpty {
                LabeledContent("Barcodes", value: "\(result.recognition.barcodes.count)")
            }

            LabeledContent("Enhance", value: milliseconds(result.timings.enhanceMs))
            LabeledContent("Recognise", value: milliseconds(result.timings.recognizeMs))
            LabeledContent("Export", value: milliseconds(result.timings.exportMs))
            if result.timings.extractMs > 0 {
                LabeledContent("Extract", value: milliseconds(result.timings.extractMs))
            }

            if let extraction = result.extraction {
                Text(extraction).font(.callout)
            }

            DisclosureGroup("Recognised text") {
                Text(result.recognition.transcript.isEmpty ? "Nothing recognised." : result.recognition.transcript)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            ShareLink(item: result.pdfURL) {
                Label("Share searchable PDF", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }
}
