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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .overlay { Color.white.opacity(flash ? 0.75 : 0).ignoresSafeArea() }

            VStack {
                HStack {
                    Button("Cancel", action: onCancel)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(.top, 8)

                Spacer()

                Text("Fill the frame with the item, then shoot")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 18)

                ShutterButton { camera.capture() }
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 22)
            .foregroundStyle(.white)

            if camera.permissionDenied { permissionNotice }
        }
        .preferredColorScheme(.dark)
        .task {
            camera.onCapture = handleCapture
            await camera.start()
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await camera.start() } } else { camera.stop() }
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.4), lineWidth: 4)
                Circle().fill(.white).padding(8)
            }
            .frame(width: 78, height: 78)
        }
        .buttonStyle(.plain)
    }
}
