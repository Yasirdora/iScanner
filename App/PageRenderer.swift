import Foundation
import CoreGraphics
import UIKit
import ScanCore
import ScanCapture
import ScanEnhance

/// `CGImage` is immutable once created and safe to pass between tasks; the
/// compiler has no way to know that.
struct SendableImage: @unchecked Sendable {
    let cgImage: CGImage

    init(_ cgImage: CGImage) { self.cgImage = cgImage }

    var uiImage: UIImage { UIImage(cgImage: cgImage) }
}

/// Does the image work off the main actor.
///
/// Rectifying and enhancing a 12-megapixel page takes long enough to drop
/// frames, and all of it used to run on the main actor — so the shutter, the
/// filter picker, and every style change froze the interface for as long as the
/// work took. An actor keeps that off the main thread without any locking at
/// the call sites.
actor PageRenderer {
    private let rectifier = PerspectiveRectifier()
    private let enhancer = DocumentEnhancer()

    /// Flattens an imported photo onto the corners of the page in it.
    func flatten(_ image: SendableImage, quad: DocumentQuad?) throws -> SendableImage {
        guard let quad else { return image }
        return SendableImage(try rectifier.rectify(
            image.cgImage,
            topLeft: quad.topLeft,
            topRight: quad.topRight,
            bottomRight: quad.bottomRight,
            bottomLeft: quad.bottomLeft
        ))
    }

    func enhance(_ image: SendableImage, style: ScanStyle) throws -> SendableImage {
        SendableImage(try enhancer.enhance(image.cgImage, style: style))
    }

}
