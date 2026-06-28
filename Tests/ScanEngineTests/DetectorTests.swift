import Testing
import CoreGraphics
import CoreML
import Foundation
@testable import ScanCapture
import ScanEnhance

// The heatmap decoder and the rectifier both run on every captured page and
// neither had a test. Both are pure given their input, so both are cheap to
// pin down.

// MARK: - Heatmap decoding

/// Four corner heatmaps with a peak at each requested position.
private func heatmaps(
    corners: [(x: Double, y: Double)],
    peak: Float = 0.9,
    side: Int = 32
) -> MLMultiArray {
    let array = try! MLMultiArray(
        shape: [1, 4, NSNumber(value: side), NSNumber(value: side)],
        dataType: .float32
    )
    array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
        for index in buffer.indices { buffer[index] = 0 }
        for (corner, position) in corners.enumerated() {
            let centreX = position.x * Double(side - 1)
            let centreY = position.y * Double(side - 1)
            // A small isotropic blob, as the network produces.
            for row in 0..<side {
                for column in 0..<side {
                    let distance = hypot(Double(column) - centreX, Double(row) - centreY)
                    guard distance <= 2.5 else { continue }
                    let value = peak * Float(exp(-distance * distance / 2))
                    buffer[corner * side * side + row * side + column] = value
                }
            }
        }
    }
    return array
}

@Test("Corners are decoded from their heatmap peaks")
func decodesCornersFromPeaks() throws {
    // Heatmap space has its origin at the top left; Vision's normalised space
    // has it at the bottom, so y is expected to come back inverted.
    let decoded = CoreMLCornerDetector.decode(heatmaps(corners: [
        (0.25, 0.25), (0.75, 0.25), (0.75, 0.75), (0.25, 0.75),
    ]))
    let (quad, confidence) = try #require(decoded)

    #expect(abs(quad.topLeft.x - 0.25) < 0.03)
    #expect(abs(quad.topLeft.y - 0.75) < 0.03)
    #expect(abs(quad.bottomRight.x - 0.75) < 0.03)
    #expect(abs(quad.bottomRight.y - 0.25) < 0.03)
    #expect(confidence > 0.5)
}

@Test("A weak heatmap is rejected rather than guessed at")
func rejectsLowConfidence() {
    // Below the threshold every peak is noise, and a quad built from noise is
    // worse than no candidate: the scorer would rank it against real ones.
    let decoded = CoreMLCornerDetector.decode(heatmaps(
        corners: [(0.25, 0.25), (0.75, 0.25), (0.75, 0.75), (0.25, 0.75)],
        peak: 0.1
    ))
    #expect(decoded == nil)
}

@Test("One weak corner rejects the whole quad")
func rejectsPartialDetection() {
    // Three good corners and one guess is a quad with one corner in the wrong
    // place, which is harder to notice than no detection at all.
    let array = heatmaps(corners: [(0.2, 0.2), (0.8, 0.2), (0.8, 0.8), (0.2, 0.8)])
    array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
        let plane = 32 * 32
        for index in (3 * plane)..<(4 * plane) { buffer[index] *= 0.05 }
    }
    #expect(CoreMLCornerDetector.decode(array) == nil)
}

@Test("Sub-pixel refinement beats the raw grid position")
func refinementImprovesOnArgmax() throws {
    // The heatmap is 128 cells across a photograph thousands of pixels wide, so
    // quantising a corner to the grid is a visible error. The blob's true
    // centre here sits between cells.
    let side = 32
    let truth = 0.4062
    let decoded = CoreMLCornerDetector.decode(heatmaps(
        corners: Array(repeating: (truth, truth), count: 4), side: side
    ))
    let quad = try #require(decoded).0

    let gridStep = 1.0 / Double(side)
    let error = abs(quad.topLeft.x - truth)
    #expect(error < gridStep / 2, "refined to \(quad.topLeft.x), truth \(truth)")
}

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
