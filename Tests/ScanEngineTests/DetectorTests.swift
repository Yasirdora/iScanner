import Testing
import CoreGraphics
import Foundation
@testable import ScanCapture
import ScanEnhance

// The rectifier runs on every captured page and had no test. It is pure given
// its input, so it is cheap to pin down.

// MARK: - Perspective rectification

@Test("Rectifying a skewed page produces an upright image")
func rectifiesToUpright() throws {
    // A white quadrilateral drawn at an angle on a dark ground; flattening it
    // should yield an image that is almost entirely white.
    let size = 400
    let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let corners = [
        CGPoint(x: 0.20, y: 0.85), CGPoint(x: 0.80, y: 0.75),
        CGPoint(x: 0.75, y: 0.20), CGPoint(x: 0.15, y: 0.30),
    ]
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.beginPath()
    context.move(to: CGPoint(x: corners[0].x * 400, y: corners[0].y * 400))
    for point in corners.dropFirst() {
        context.addLine(to: CGPoint(x: point.x * 400, y: point.y * 400))
    }
    context.closePath()
    context.fillPath()

    let source = context.makeImage()!
    let flattened = try PerspectiveRectifier().rectify(
        source,
        topLeft: corners[0], topRight: corners[1],
        bottomRight: corners[2], bottomLeft: corners[3]
    )

    // Sample the middle, away from the edges where interpolation blends.
    var pixels = [UInt8](repeating: 0, count: flattened.width * flattened.height * 4)
    let readback = CGContext(
        data: &pixels, width: flattened.width, height: flattened.height,
        bitsPerComponent: 8, bytesPerRow: flattened.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    readback.draw(flattened, in: CGRect(x: 0, y: 0, width: flattened.width, height: flattened.height))

    var bright = 0, total = 0
    for row in (flattened.height / 4)..<(flattened.height * 3 / 4) {
        for column in (flattened.width / 4)..<(flattened.width * 3 / 4) {
            total += 1
            if pixels[(row * flattened.width + column) * 4] > 200 { bright += 1 }
        }
    }
    #expect(Double(bright) / Double(total) > 0.95, "the flattened page was not the page")
}

@Test("Rectifying without corners returns the image untouched")
func rectifyIsOptional() throws {
    let context = CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let source = context.makeImage()!
    let unchanged = try PerspectiveRectifier().rectify(
        source,
        topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1),
        bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 0)
    )
    #expect(unchanged.width == source.width)
    #expect(unchanged.height == source.height)
}
