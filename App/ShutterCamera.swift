import AVFoundation
import Observation
import SwiftUI

/// A camera with a shutter and nothing else.
///
/// Deliberately does no work while framing. Detection quality is driven by how
/// much text Vision can read, and that scales with resolution: at the ~512
/// pixels a live pass can afford it finds two or three lines on a printed card
/// against seven on the captured still, and below that threshold it picks the
/// wrong object entirely — measured, on two of three real photographs.
///
/// So the page is found *after* the shutter, at full resolution, where the
/// answer is right. Nothing here runs per frame, which also means no frame
/// budget, no thermal load, and no chance of the viewfinder stuttering.
@Observable
@MainActor
final class ShutterCamera: NSObject {

    private(set) var permissionDenied = false
    var onCapture: ((CGImage) -> Void)?
    /// How the next capture is lit: auto, on, or off. Cycled from the shutter
    /// screen; settings are built per shot, so this is read at shutter time.
    var flashMode: AVCaptureDevice.FlashMode = .auto

    /// `AVCaptureSession` is not `Sendable`, but starting and stopping it off
    /// the main thread is what Apple's own sample code does — `startRunning()`
    /// blocks long enough to drop frames. Configuration stays on the main actor.
    nonisolated(unsafe) let session = AVCaptureSession()

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "scanner.session")
    private var isCapturing = false
    @ObservationIgnored private var device: AVCaptureDevice?

    // MARK: - Lifecycle

    func start() async {
        guard await authorized() else {
            permissionDenied = true
            return
        }
        configureIfNeeded()

        let session = self.session
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    private func configureIfNeeded() {
        guard session.inputs.isEmpty else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        self.device = device
        session.addInput(input)
        configureFocus(on: device)

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // Portrait. The still's corners are used to rectify it, so a capture
        // left in sensor orientation would be flattened against a description
        // of a rotated version of itself.
        photoOutput.connection(with: .video)?.videoRotationAngle = 90
    }

    private func configureFocus(on device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        // Documents sit close. Without this the lens hunts across its whole
        // range every time the page moves.
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    // MARK: - Focus

    /// One-shot focus and metering at a point on the preview, in device
    /// coordinates. The camera drifts back to continuous once the shot is
    /// taken, so this never strands the viewfinder on a bad guess.
    func focus(at point: CGPoint) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
        }
    }

    // MARK: - Shutter

    func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(flashMode) {
            settings.flashMode = flashMode
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
        // A metering tap leaves focus in one-shot mode; hand it back to
        // continuous so the viewfinder is live again for the next page.
        if let device {
            configureFocus(on: device)
        }
    }
}

extension ShutterCamera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        let image = photo.cgImageRepresentation()
        Task { @MainActor in
            defer { isCapturing = false }
            guard error == nil, let image else { return }
            onCapture?(image)
        }
    }
}
