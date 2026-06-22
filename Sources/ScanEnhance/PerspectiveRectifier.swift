import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ScanCore

/// Flattens a page photographed at an angle into a square-on rectangle.
///
/// This is the step VisionKit performed invisibly. Doing it here means the
/// corners come from the same detection the shutter decision was made on, so
/// what the viewfinder outlined is exactly what gets rectified — rather than
/// the scanner re-detecting after the fact and disagreeing with what the user
/// was shown.
public struct PerspectiveRectifier: Sendable {

    private let context: CIContext

    public init(context: CIContext? = nil) {
        self.context = context ?? CIContext(options: [.cacheIntermediates: false])
    }

    /// Corners are normalised with the origin at the lower left, as Vision
    /// reports them.
    public func rectify(
        _ image: CGImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomRight: CGPoint,
        bottomLeft: CGPoint
    ) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let size = source.extent.size

        func denormalize(_ point: CGPoint) -> CIVector {
            CIVector(x: point.x * size.width, y: point.y * size.height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = source
        filter.topLeft = denormalize(topLeft).cgPointValue
        filter.topRight = denormalize(topRight).cgPointValue
        filter.bottomRight = denormalize(bottomRight).cgPointValue
        filter.bottomLeft = denormalize(bottomLeft).cgPointValue
        // Core Image's crop-and-perspective variant would also clip; this one
        // keeps every pixel inside the quad and nothing outside it.
        filter.crop = true

        guard let output = filter.outputImage,
              let result = context.createCGImage(output, from: output.extent) else {
            throw EnhancementError.renderFailed
        }
        return result
    }
}

private extension CIVector {
    var cgPointValue: CGPoint { CGPoint(x: x, y: y) }
}
