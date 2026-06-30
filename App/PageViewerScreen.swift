import SwiftUI

/// Full-screen reader for scanned pages.
///
/// Swipe between pages, pinch or double-tap to zoom, select text, tap a
/// telephone number or a link. The chrome hides on a tap so the page has the
/// whole screen, which is the point of opening it.
struct PageViewerScreen: View {
    let results: [ScanResult]
    @State var selection: Int
    var onDone: () -> Void
    var onDelete: (ScanResult.ID) -> Void

    @State private var isChromeVisible = true
    @State private var showDeleteConfirm = false
    @State private var tipVisible = false
    @AppStorage("hasSeenViewerTip") private var hasSeenTip = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    PageViewer(image: result.enhanced)
                        .ignoresSafeArea()
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { isChromeVisible.toggle() }
            }

            if isChromeVisible { chrome }
            if tipVisible { tip }
        }
        .statusBarHidden(!isChromeVisible)
        .sensoryFeedback(.selection, trigger: selection)
        .task {
            guard !hasSeenTip else { return }
            hasSeenTip = true
            withAnimation { tipVisible = true }
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation { tipVisible = false }
        }
        .confirmationDialog(
            "Delete this page?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Page", role: .destructive) {
                if let result = results[safe: selection] {
                    onDelete(result.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page will be removed from this session.")
        }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if results.count > 1 { rail }
        }
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack {
            Button {
                onDone()
            } label: {
                glassIcon("xmark")
            }
            .accessibilityLabel("Close")

            Spacer()

            Menu {
                if let result = results[safe: selection] {
                    ShareLink(item: result.pdfURL) {
                        Label("Share PDF", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete Page", systemImage: "trash")
                }
            } label: {
                glassIcon("ellipsis")
            }
            .accessibilityLabel("Page Actions")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func glassIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial, in: Circle())
    }

    /// The page rail: jump anywhere in the document without swiping through it.
    private var rail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selection = index }
                        } label: {
                            Image(uiImage: result.thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 46, height: 58)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(
                                            index == selection ? Color.accentColor : Color.primary.opacity(0.15),
                                            lineWidth: index == selection ? 2.5 : 0.5
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .accessibilityLabel("Page \(index + 1)")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(newValue, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .background(.ultraThinMaterial)
    }

    /// A one-time tip: it appears the first time a page is opened and never
    /// again, because a hint that never leaves stops being a hint.
    private var tip: some View {
        VStack {
            Spacer()
            Label("Select text, or tap a number or link", systemImage: "text.viewfinder")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, results.count > 1 ? 96 : 26)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
