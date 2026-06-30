import SwiftUI

/// One page in the session grid: the page itself, what it is, and what the
/// engine is doing with it while it finishes.
struct PageCard: View {
    let page: PageItem
    let index: Int
    var onOpen: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if page.stage.isReady { onOpen() }
            } label: {
                thumbnail
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page \(index + 1), \(page.title)")
            .accessibilityValue(statusDescription)
            .accessibilityHint(page.stage.isReady ? "Opens the page" : "")

            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(index + 1)")
                    .font(.subheadline.weight(.semibold))
                Text(page.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
        }
        .contextMenu {
            if page.stage.isReady {
                Button(action: onOpen) {
                    Label("Open", systemImage: "doc.text.magnifyingglass")
                }
            }
            if let url = page.result?.pdfURL {
                ShareLink(item: url) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete Page", systemImage: "trash")
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            Image(uiImage: page.result?.enhanced ?? page.source)
                .resizable()
                .scaledToFit()
                .padding(10)
                .opacity(page.stage.isReady ? 1 : 0.45)
            status
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch page.stage {
        case .enhancing, .recognizing, .exporting:
            VStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(page.stageLabel)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 12)

        case .failed(let message):
            VStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Couldn't finish")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(12)

        case .ready:
            EmptyView()
        }
    }

    private var statusDescription: String {
        switch page.stage {
        case .enhancing: "Enhancing"
        case .recognizing: "Reading text"
        case .exporting: "Building PDF"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}
