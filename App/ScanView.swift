import PhotosUI
import ScanCapture
import ScanCore
import SwiftUI
import UIKit

/// The app's home: the pages captured so far, and the ways to add one.
struct ScanView: View {
    @State private var pipeline = ScanPipeline()
    @State private var destination: Destination?
    @State private var photoItem: PhotosPickerItem?
    @State private var isFindingPage = false
    @State private var confirmDeleteAll = false
    @State private var sharePayload: SharePayload?
    @State private var deleted: (page: PageItem, index: Int)?
    @State private var undoTask: Task<Void, Never>?
    @Namespace private var pageTransition
    @AppStorage("scanStyle") private var styleRaw = ScanStyle.auto.rawValue

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
        /// Plain shutter, for a small item on a larger surface.
        case itemCamera
        /// Confirming the detected edges of a photo before it is processed.
        case adjustEdges(image: UIImage, quad: DocumentQuad?, retake: Bool)
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

    private var style: ScanStyle { ScanStyle(rawValue: styleRaw) ?? .auto }
    private var readyResults: [ScanResult] { pipeline.pages.compactMap(\.result) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scanner")
                .toolbar {
                    topBar
                    bottomBar
                }
                .overlay { findingOverlay }
                .overlay(alignment: .bottom) { undoSnackbar }
                .fullScreenCover(item: $destination, content: cover)
                .sheet(item: $sharePayload) { payload in
                    ActivityView(items: [payload.url])
                }
                .confirmationDialog(
                    "Delete all scans?",
                    isPresented: $confirmDeleteAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete All", role: .destructive) {
                        withAnimation { pipeline.clear() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("\(pipeline.pages.count) page\(pipeline.pages.count == 1 ? "" : "s") will be deleted. This can't be undone.")
                }
                .onChange(of: photoItem, handlePhotoSelection)
                .onChange(of: styleRaw) { _, _ in pipeline.style = style }
                .onAppear { pipeline.style = style }
                .task {
                    #if DEBUG
                    await runDemoIfRequested()
                    #endif
                }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if pipeline.pages.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 156), spacing: 18)],
                    spacing: 20
                ) {
                    ForEach(Array(pipeline.pages.enumerated()), id: \.element.id) { index, page in
                        PageCard(page: page, index: index) {
                            open(page)
                        } onDelete: {
                            delete(page)
                        }
                        .matchedTransitionSource(id: page.result?.id ?? page.id, in: pageTransition)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .animation(.spring(duration: 0.4), value: pipeline.pages.count)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No scans yet", systemImage: "doc.viewfinder")
        } description: {
            Text("Scan a page or import a photo. Everything is processed on this device.")
        } actions: {
            Button {
                destination = .documentScanner
            } label: {
                Text("Scan a Document")
            }
            .buttonStyle(.borderedProminent)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Import a Photo")
            }
        }
    }

    @ViewBuilder
    private var findingOverlay: some View {
        if isFindingPage {
            ProgressView("Finding the page")
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var undoSnackbar: some View {
        if deleted != nil {
            HStack(spacing: 14) {
                Text("Page deleted")
                    .font(.subheadline)
                Button("Undo", action: undoDelete)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 66)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var topBar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !readyResults.isEmpty {
                    Button(action: shareAll) {
                        Label("Share All as PDF", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                }
                Button {
                    destination = .itemCamera
                } label: {
                    Label("Scan a Small Item", systemImage: "viewfinder.rectangular")
                }
                Picker("Scan Look", selection: $styleRaw) {
                    ForEach(ScanStyle.offered, id: \.self) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                if !pipeline.pages.isEmpty {
                    Divider()
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Delete All Scans", systemImage: "trash")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ToolbarContentBuilder
    private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Import", systemImage: "photo.on.rectangle.angled")
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

    // MARK: - Flows

    private func open(_ page: PageItem) {
        guard page.stage.isReady,
              let resultID = page.result?.id,
              let index = readyResults.firstIndex(where: { $0.id == resultID }) else { return }
        destination = .viewPage(index: index)
    }

    private func shareAll() {
        guard let url = pipeline.exportAllPDF() else { return }
        sharePayload = SharePayload(url: url)
    }

    private func delete(_ page: PageItem) {
        guard let index = pipeline.pages.firstIndex(where: { $0.id == page.id }) else { return }
        withAnimation { pipeline.remove(page.id) }
        deleted = (page, index)
        undoTask?.cancel()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { deleted = nil }
        }
    }

    private func undoDelete() {
        undoTask?.cancel()
        guard let record = deleted else { return }
        withAnimation { pipeline.insert(record.page, at: record.index) }
        deleted = nil
    }

    /// The card a presented page zooms out of, so the two animations match.
    private func viewerSourceID(for index: Int) -> UUID {
        readyResults.indices.contains(index) ? readyResults[index].id : UUID()
    }

    /// An imported or hand-shot photo is a whole picture, not a page: the
    /// document sits somewhere inside it. Detection is reliable about *which*
    /// object is the page and only approximate about its edge, so the corners
    /// are always offered rather than applied silently.
    private func findPage(in image: UIImage, retake: Bool) async {
        isFindingPage = true
        let quad = await pipeline.findDocument(in: image)
        isFindingPage = false
        destination = .adjustEdges(image: image, quad: quad, retake: retake)
    }

    private func handlePhotoSelection(_ previous: PhotosPickerItem?, _ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            await findPage(in: image, retake: false)
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
                onCapture: { image in Task { await findPage(in: image, retake: true) } }
            )

        case .viewPage(let index):
            PageViewerScreen(
                results: readyResults,
                selection: index,
                onDone: { self.destination = nil },
                onDelete: { id in
                    if let page = pipeline.pages.first(where: { $0.result?.id == id }) {
                        delete(page)
                    }
                    self.destination = nil
                }
            )
            .navigationTransition(.zoom(sourceID: viewerSourceID(for: index), in: pageTransition))

        case .adjustEdges(let image, let quad, let retake):
            CropEditor(
                image: image,
                quad: quad,
                dismissTitle: retake ? "Retake" : "Cancel",
                onCancel: { self.destination = nil },
                onApply: { corrected in
                    self.destination = nil
                    Task { await pipeline.run(imported: image, quad: corrected) }
                }
            )
        }
    }

    // MARK: - Development

    #if DEBUG
    /// Drives a flow without fingers, so screens can be exercised in the
    /// simulator — which has no camera and cannot be tapped headlessly. Set
    /// `SCANNER_DEMO` to comma-separated tokens: `import:<path>`,
    /// `crop:<path>`, `smallitem`, `viewer`.
    private func runDemoIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["SCANNER_DEMO"] else { return }
        var openViewer = false

        for token in spec.split(separator: ",").map(String.init) {
            if token == "viewer" {
                openViewer = true
            } else if token == "smallitem" {
                destination = .itemCamera
            } else if token.hasPrefix("import:") {
                let path = String(token.dropFirst("import:".count))
                if let image = UIImage(contentsOfFile: path) {
                    await pipeline.run(imported: image, quad: nil)
                }
            } else if token.hasPrefix("crop:") {
                let path = String(token.dropFirst("crop:".count))
                if let image = UIImage(contentsOfFile: path) {
                    await findPage(in: image, retake: false)
                }
            }
        }

        if openViewer, !readyResults.isEmpty {
            destination = .viewPage(index: 0)
        }
    }
    #endif
}

// MARK: - Sharing

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
