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

    @State private var isChromeVisible = true

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
        }
        .statusBarHidden(!isChromeVisible)
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button("Done", action: onDone)
                    .font(.body.weight(.semibold))
                Spacer()
                if results.count > 1 {
                    Text("\(selection + 1) of \(results.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let result = results[safe: selection] {
                    ShareLink(item: result.pdfURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)

            Spacer()

            Label("Select text, or tap a number or link", systemImage: "text.viewfinder")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
        .transition(.opacity)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
