import Foundation
import CoreGraphics
import CoreVideo
import ImageIO
import CoreImage
import Vision

/// Finds the page outline in a camera frame.
///
/// Uses Vision's learned document segmenter rather than classical rectangle
/// detection. `DetectRectanglesRequest` looks for four strong straight edges
/// and gives up on a white page against a pale desk, a page with a torn edge,
/// or a receipt with a curled corner — all common. The segmenter was trained on
/// documents and returns a quad for cases that have no clean edges at all.
public struct DocumentDetector: Sendable {

    public init() {}

    public func detect(
        in frame: CameraFrame,
        orientation: CGImagePropertyOrientation
    ) async throws -> (quad: DocumentQuad, confidence: Float)? {
        let request = DetectDocumentSegmentationRequest()
        let handler = ImageRequestHandler(frame.buffer, orientation: orientation)
        guard let observation = try await handler.perform(request) else { return nil }
        return (quad(from: observation), observation.confidence)
    }

    /// Detects in a still image, optionally ignoring everything outside a
    /// region of the frame.
    ///
    /// The region of interest is the knob `VNDocumentCameraViewController` does
    /// not have. On a page lying on top of other rectangular things — a receipt
    /// on a notebook on a table — the largest, strongest quad is rarely the one
    /// the user means, and restricting the search is the direct fix.
    public func detect(
        in image: CGImage,
        regionOfInterest: CGRect? = nil
    ) async throws -> (quad: DocumentQuad, confidence: Float)? {
        var request = DetectDocumentSegmentationRequest()
        if let regionOfInterest {
            request.regionOfInterest = NormalizedRect(
                x: regionOfInterest.minX,
                y: regionOfInterest.minY,
                width: regionOfInterest.width,
                height: regionOfInterest.height
            )
        }
        let handler = ImageRequestHandler(image)
        guard let observation = try await handler.perform(request) else { return nil }
        return (quad(from: observation), observation.confidence)
    }

    private func quad(from observation: DetectedDocumentObservation) -> DocumentQuad {
        DocumentQuad(
            topLeft: observation.topLeft.cgPoint,
            topRight: observation.topRight.cgPoint,
            bottomRight: observation.bottomRight.cgPoint,
            bottomLeft: observation.bottomLeft.cgPoint
        )
    }
}

/// One camera frame on its way to the detector.
///
/// `CVPixelBuffer` is a Core Foundation type and carries no `Sendable`
/// conformance, but the capture path hands each buffer to exactly one consumer
/// and drops frames that arrive while a detection is in flight, so no two tasks
/// ever hold the same buffer. The wrapper states that invariant rather than
/// scattering unchecked conversions through the call sites.
public struct CameraFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }

    public var size: CGSize {
        CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }
}

extension CameraFrame {
    /// Renders the frame to a still no wider than `maxWidth`.
    ///
    /// The candidate selector needs a `CGImage` and its cost rises steeply with
    /// resolution — measured at 144 ms for a 512-pixel frame against 235 ms at
    /// 768 — so the frame is reduced before it is handed over. Detection at
    /// this size is only used to place an outline; the crop that matters is
    /// computed later from the full-resolution capture.
    public func image(maxWidth: Int, context: CIContext) -> CGImage? {
        let source = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, Double(maxWidth) / Double(source.extent.width))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
