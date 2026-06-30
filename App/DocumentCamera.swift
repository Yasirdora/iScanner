import SwiftUI
import VisionKit
import UIKit

/// Bridges VisionKit's document camera into SwiftUI.
///
/// This is Apple's scanner — the one in Notes and Files. It was replaced with a
/// custom AVFoundation pipeline and that was a mistake: it is faster than what
/// can be rebuilt on top of Vision frame by frame, and it already provides
/// corner adjustment, retake, and multi-page review, all of which had to be
/// reimplemented worse. Its limits are real — a session caps at roughly two
/// dozen pages and there is no hook for a live enhancement preview — but
/// neither costs as much as losing the responsiveness did.
struct DocumentCamera: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void

        init(onFinish: @escaping ([UIImage]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            onFinish([])
        }
    }
}
