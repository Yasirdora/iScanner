import SwiftUI
import ScanCapture

/// Lets the user correct the detected page corners.
///
/// Detection reliably finds the right object and only approximately finds its
/// edge, so the corners have to be movable. The magnifier is not decoration: a
/// fingertip covers the very corner it is placing.
struct CropEditor: View {
    let image: UIImage
    @State private var corners: [CGPoint]
    @State private var dragging: Int?
    var onCancel: () -> Void
    var onApply: (DocumentQuad) -> Void

    init(
        image: UIImage,
        quad: DocumentQuad?,
        onCancel: @escaping () -> Void,
        onApply: @escaping (DocumentQuad) -> Void
    ) {
        self.image = image
        // Vision's origin is bottom-left; the editor works top-left like the
        // view it draws into, so corners flip once in and once out.
        let source = quad ?? DocumentQuad(
            topLeft: CGPoint(x: 0.06, y: 0.94),
            topRight: CGPoint(x: 0.94, y: 0.94),
            bottomRight: CGPoint(x: 0.94, y: 0.06),
            bottomLeft: CGPoint(x: 0.06, y: 0.06)
        )
        _corners = State(initialValue: source.corners.map { CGPoint(x: $0.x, y: 1 - $0.y) })
        self.onCancel = onCancel
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let frame = fittedRect(in: geometry.size)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    CropShape(corners: corners, frame: frame)
                        .fill(Color.accentColor.opacity(0.14))
                    CropShape(corners: corners, frame: frame)
                        .stroke(Color.accentColor, lineWidth: 2.5)

                    ForEach(corners.indices, id: \.self) { index in
                        handle(at: index, in: frame)
                    }

                    if let dragging {
                        Magnifier(image: image, focus: corners[dragging])
                            .position(magnifierPosition(for: corners[dragging], in: geometry.size))
                            .allowsHitTesting(false)
                    }
                }
            }
            .navigationTitle("Adjust edges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") {
                        onApply(DocumentQuad(
                            topLeft: flip(corners[0]),
                            topRight: flip(corners[1]),
                            bottomRight: flip(corners[2]),
                            bottomLeft: flip(corners[3])
                        ))
                    }
                    .font(.body.weight(.semibold))
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Whole photo") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            corners = [
                                CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
                            ]
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func flip(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    private func handle(at index: Int, in frame: CGRect) -> some View {
        let point = CGPoint(
            x: frame.minX + corners[index].x * frame.width,
            y: frame.minY + corners[index].y * frame.height
        )
        return Circle()
            .fill(.white)
            .frame(width: 18, height: 18)
            .overlay { Circle().stroke(Color.accentColor, lineWidth: 3) }
            .shadow(radius: 2)
            .position(point)
            // A generous invisible target: an 18-point dot is far smaller than a
            // fingertip, and missing the handle drags nothing at all.
            .contentShape(Circle().size(width: 64, height: 64))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = index
                        corners[index] = CGPoint(
                            x: ((value.location.x - frame.minX) / frame.width).clamped(),
                            y: ((value.location.y - frame.minY) / frame.height).clamped()
                        )
                    }
                    .onEnded { _ in dragging = nil }
            )
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
