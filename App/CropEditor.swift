import SwiftUI
import ScanCapture

/// Lets the user correct the detected page corners.
///
/// Detection reliably finds the right object and only approximately finds its
/// edge, so the corners have to be movable. The magnifier is not decoration: a
/// fingertip covers the very corner it is placing.
struct CropEditor: View {
    let image: UIImage
    var dismissTitle = "Retake"
    @State private var corners: [CGPoint]
    @State private var detected: [CGPoint]
    @State private var dragging: Int?
    /// Where the finger took hold of the corner, relative to the corner, so a
    /// drag moves the corner by the finger's movement instead of jumping it to
    /// the touch point.
    @State private var grabOffset: CGSize = .zero
    var onCancel: () -> Void
    var onApply: (DocumentQuad) -> Void

    init(
        image: UIImage,
        quad: DocumentQuad?,
        dismissTitle: String = "Retake",
        onCancel: @escaping () -> Void,
        onApply: @escaping (DocumentQuad) -> Void
    ) {
        self.image = image
        self.dismissTitle = dismissTitle
        // Vision's origin is bottom-left; the editor works top-left like the
        // view it draws into, so corners flip once in and once out.
        let source = quad ?? DocumentQuad(
            topLeft: CGPoint(x: 0.06, y: 0.94),
            topRight: CGPoint(x: 0.94, y: 0.94),
            bottomRight: CGPoint(x: 0.94, y: 0.06),
            bottomLeft: CGPoint(x: 0.06, y: 0.06)
        )
        let flipped = source.corners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
        _corners = State(initialValue: flipped)
        _detected = State(initialValue: flipped)
        self.onCancel = onCancel
        self.onApply = onApply
    }

    /// The whole photo, in the editor's top-left coordinates.
    private static let fullFrame = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]

    private static let cornerNames = ["Top left", "Top right", "Bottom right", "Bottom left"]

    /// The space handles are dragged in: the editor's own, not the handle's.
    private static let space = "crop"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geometry in
                let frame = fittedRect(in: geometry.size)
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    // Everything outside the page dims, so the crop reads as
                    // the subject and the rest as context.
                    CropBackdrop(corners: corners, frame: frame)
                        .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))
                    CropShape(corners: corners, frame: frame)
                        .stroke(.white, lineWidth: 2)
                        .shadow(color: .black.opacity(0.4), radius: 2)

                    ForEach(corners.indices, id: \.self) { index in
                        handle(at: index, in: frame)
                    }

                    if let dragging {
                        Magnifier(image: image, focus: corners[dragging])
                            .position(magnifierPosition(for: corners[dragging], in: geometry.size))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(.named(Self.space))
            }
            .ignoresSafeArea()

            bottomBar
        }
        .preferredColorScheme(.dark)
    }

    private var bottomBar: some View {
        VStack {
            Spacer()
            HStack {
                Button(dismissTitle, action: onCancel)
                    .font(.body.weight(.medium))

                Spacer()

                Menu {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { corners = detected }
                    } label: {
                        Label("Detected Corners", systemImage: "viewfinder")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { corners = Self.fullFrame }
                    } label: {
                        Label("Full Photo", systemImage: "photo")
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Reset corners")

                Spacer()

                Button("Keep") {
                    onApply(DocumentQuad(
                        topLeft: flip(corners[0]),
                        topRight: flip(corners[1]),
                        bottomRight: flip(corners[2]),
                        bottomLeft: flip(corners[3])
                    ))
                }
                .font(.body.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            .foregroundStyle(.white)
        }
    }

    private func handle(at index: Int, in frame: CGRect) -> some View {
        let point = CGPoint(
            x: frame.minX + corners[index].x * frame.width,
            y: frame.minY + corners[index].y * frame.height
        )
        return Circle()
            .fill(.white)
            .frame(width: 20, height: 20)
            .overlay { Circle().stroke(Color.accentColor, lineWidth: 3) }
            .shadow(radius: 2)
            // A generous invisible target: a 20-point dot is far smaller than
            // a fingertip, and missing the handle drags nothing at all.
            //
            // Shaped and given its gesture before it is positioned. `position`
            // makes a view as large as its container, so a content shape added
            // after it sat at the container's top-left corner — where no corner
            // is — and the dots on screen could not be moved at all.
            .frame(width: 64, height: 64)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        if dragging != index {
                            dragging = index
                            grabOffset = CGSize(
                                width: point.x - value.startLocation.x,
                                height: point.y - value.startLocation.y
                            )
                        }
                        corners[index] = CGPoint(
                            x: ((value.location.x + grabOffset.width - frame.minX) / frame.width).clamped(),
                            y: ((value.location.y + grabOffset.height - frame.minY) / frame.height).clamped()
                        )
                    }
                    .onEnded { _ in dragging = nil }
            )
            .sensoryFeedback(.selection, trigger: dragging)
            // Dragging is not the only way in: VoiceOver gets an adjustable
            // action, and the reset menu is a plain button.
            .accessibilityElement()
            .accessibilityLabel(Self.cornerNames[index])
            .accessibilityValue(accessibilityValue(index))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 0.02 : -0.02
                let corner = corners[index]
                withAnimation(.easeInOut(duration: 0.12)) {
                    corners[index] = CGPoint(
                        x: (corner.x + (corner.x < 0.5 ? -step : step)).clamped(),
                        y: (corner.y + (corner.y < 0.5 ? -step : step)).clamped()
                    )
                }
            }
            .position(point)
    }

    private func accessibilityValue(_ index: Int) -> String {
        let corner = corners[index]
        return "\(Int((corner.x * 100).rounded()))%, \(Int((corner.y * 100).rounded()))%"
    }

    private func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Keeps the loupe away from the finger holding the corner.
    private func magnifierPosition(for corner: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: corner.x < 0.5 ? size.width - 90 : 90, y: 96)
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let aspect = image.size.width / max(image.size.height, 1)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width, height: height
        )
    }
}

// MARK: - Shapes

private struct CropShape: Shape {
    let corners: [CGPoint]
    let frame: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = corners.map {
            CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// The full view plus the page quad; filled even-odd, this is everything
/// *outside* the page.
private struct CropBackdrop: Shape {
    let corners: [CGPoint]
    let frame: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let points = corners.map {
            CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
        }
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Magnifier

private struct Magnifier: View {
    let image: UIImage
    let focus: CGPoint

    private let diameter: CGFloat = 118
    private let zoom: CGFloat = 3

    var body: some View {
        let displayed = CGSize(
            width: diameter * zoom,
            height: diameter * zoom * image.size.height / max(image.size.width, 1)
        )
        Circle()
            .fill(.black)
            .frame(width: diameter, height: diameter)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: displayed.width, height: displayed.height)
                    .offset(
                        x: displayed.width * (0.5 - focus.x),
                        y: displayed.height * (0.5 - focus.y)
                    )
                    .clipShape(Circle())
            }
            .overlay { Circle().stroke(.white.opacity(0.9), lineWidth: 3) }
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: diameter / 2 - 10, y: diameter / 2))
                    path.addLine(to: CGPoint(x: diameter / 2 + 10, y: diameter / 2))
                    path.move(to: CGPoint(x: diameter / 2, y: diameter / 2 - 10))
                    path.addLine(to: CGPoint(x: diameter / 2, y: diameter / 2 + 10))
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
            }
            .shadow(radius: 8)
    }
}

private extension CGFloat {
    func clamped() -> CGFloat { Swift.min(Swift.max(self, 0), 1) }
}
