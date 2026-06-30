import AVFoundation
import SwiftUI

/// Full-screen viewfinder for capturing one item.
///
/// No outline and no automatic capture. Both would need detection running on
/// the frame path, and at the resolution that allows, detection picks the wrong
/// object more often than the right one. The page is found after the shutter,
/// and the corners are offered before anything is processed.
struct ShutterCameraView: View {
    var onCancel: () -> Void
    var onCapture: (UIImage) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = ShutterCamera()
    @State private var flash = false
    @State private var showHint = true
    @State private var focusReticle: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session) { devicePoint, layerPoint in
                focus(at: devicePoint, layerPoint: layerPoint)
            }
            .ignoresSafeArea()
            .overlay { Color.white.opacity(flash ? 0.75 : 0).ignoresSafeArea() }

            scrims

            if let focusReticle {
                Circle()
                    .stroke(.yellow.opacity(0.9), lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(focusReticle)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    glassButton(systemImage: "xmark", label: "Close", action: onCancel)
                    Spacer()
                    glassButton(systemImage: flashIcon, label: flashLabel, action: cycleFlash)
                }
                .padding(.top, 8)

                Spacer()

                if showHint { hintText }

                ShutterButton { camera.capture() }
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
            .foregroundStyle(.white)

            if camera.permissionDenied { permissionNotice }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: camera.flashMode)
        .task {
            camera.onCapture = handleCapture
            await camera.start()
        }
        .task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.4)) { showHint = false }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await camera.start() } } else { camera.stop() }
        }
    }

    // MARK: - Pieces

    /// Darkens the top and bottom edges so the controls stay legible over
    /// whatever the camera is pointing at.
    private var scrims: some View {
        VStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 200)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var hintText: some View {
        Text("Line up the item, then tap to capture")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 18)
            .transition(.opacity)
    }

    private func glassButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }

    private var flashIcon: String {
        switch camera.flashMode {
        case .auto: "bolt.badge.a"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        @unknown default: "bolt.slash.fill"
        }
    }

    private var flashLabel: String {
        switch camera.flashMode {
        case .auto: "Flash: Automatic"
        case .on: "Flash: On"
        case .off: "Flash: Off"
        @unknown default: "Flash"
        }
    }

    private func cycleFlash() {
        switch camera.flashMode {
        case .auto: camera.flashMode = .on
        case .on: camera.flashMode = .off
        case .off: camera.flashMode = .auto
        @unknown default: camera.flashMode = .auto
        }
    }

    /// Tap to focus and meter, with a reticle where the finger landed — the
    /// gesture every camera on this platform has.
    private func focus(at devicePoint: CGPoint, layerPoint: CGPoint) {
        camera.focus(at: devicePoint)
        withAnimation(.easeOut(duration: 0.15)) { focusReticle = layerPoint }
        Task {
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.easeOut(duration: 0.3)) {
                if focusReticle == layerPoint { focusReticle = nil }
            }
        }
    }

    private var permissionNotice: some View {
        ContentUnavailableView {
            Label("Camera access needed", systemImage: "camera.fill")
        } description: {
            Text("Turn the camera on in Settings to capture a page.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.black)
    }

    private func handleCapture(_ image: CGImage) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.22).delay(0.08)) { flash = false }
        onCapture(UIImage(cgImage: image))
    }
}

// MARK: - Components

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Receives a tap on the preview as two points: device coordinates for the
    /// camera, layer coordinates for the reticle.
    var onTap: ((CGPoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.onTap = onTap
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onTap = onTap
    }

    final class PreviewView: UIView {
        var onTap: ((CGPoint, CGPoint) -> Void)?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            let point = gesture.location(in: self)
            let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(devicePoint, point)
        }
    }
}

struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 5)
                Circle().fill(.white).padding(9)
            }
            .frame(width: 80, height: 80)
        }
        .buttonStyle(ShutterButtonStyle())
        .accessibilityLabel("Capture")
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
