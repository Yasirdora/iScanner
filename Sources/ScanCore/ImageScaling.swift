import CoreGraphics

public extension CGImage {
    /// A copy no wider than `width`, or the original if it is already smaller.
    ///
    /// Used to hold work to the resolution it was verified at. Detection in
    /// particular costs far more on a full 12-megapixel frame than the extra
    /// pixels contribute, and its result is normalised, so it applies to the
    /// original unchanged.
    func downscaled(toWidth width: Int) -> CGImage? {
        guard self.width > width, width > 0 else { return self }

        let scale = Double(width) / Double(self.width)
        let height = Int((Double(self.height) * scale).rounded())
        guard height > 0 else { return self }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
