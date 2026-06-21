import CoreGraphics
import CoreML
import Foundation

/// Runs DocAligner's corner detector through Core ML.
///
/// The network takes a 256×256 RGB image with values in 0...1 and returns four
/// heatmaps at 128×128 — one per corner, ordered top-left, top-right,
/// bottom-right, bottom-left. A corner is the peak of its heatmap.
///
/// Converted from the published ONNX (Apache 2.0) with its einsum nodes
/// rewritten and weights kept in float32; `Docs/PLAN.md` records why half
/// precision was rejected. On this project's reference photographs it matches
/// Apple's own detector on full pages and finds nothing on a small card lying
/// on a larger sheet, so it is offered to the scorer as one candidate among
/// several rather than trusted on its own.
///
/// Takes an already-loaded `MLModel` so the app can use the bundle's compiled
/// asset while the evaluation harness compiles one at runtime, and both run
/// exactly the same decoding.
/// `MLModel` carries no `Sendable` conformance, but Apple documents prediction
/// as safe to call concurrently on one instance, and nothing here mutates it.
public struct CoreMLCornerDetector: DocumentCornerPredicting, @unchecked Sendable {

    /// The network's fixed input geometry.
    private static let inputSide = 256
    /// Peak height below which a heatmap is treated as holding no corner.
    /// Matches the reference implementation's own threshold.
    private static let confidenceThreshold: Float = 0.3
    /// Half-width of the window used to refine a peak to sub-pixel accuracy.
    private static let refinementRadius = 2

    private let model: MLModel

    public init(model: MLModel) {
        self.model = model
    }

    public func corners(in image: CGImage) async -> (quad: DocumentQuad, confidence: Float)? {
        guard let input = Self.makeInput(from: image),
              let features = try? MLDictionaryFeatureProvider(dictionary: ["img": input]),
              let result = try? await model.prediction(from: features),
              let heatmaps = result.featureValue(for: "heatmap")?.multiArrayValue else {
            return nil
        }
        return Self.decode(heatmaps)
    }

    // MARK: - Input

    /// Draws the image into the network's expected 1×3×256×256 float buffer.
    static func makeInput(from image: CGImage) -> MLMultiArray? {
        let side = inputSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)

        guard let context = CGContext(
            data: &pixels,
            width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        ) else { return nil }

        // Channel-first, scaled to 0...1, matching the reference preprocessing.
        let plane = side * side
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
            for row in 0..<side {
                for column in 0..<side {
                    let source = (row * side + column) * 4
                    let destination = row * side + column
                    buffer[destination] = Float(pixels[source]) / 255
                    buffer[plane + destination] = Float(pixels[source + 1]) / 255
                    buffer[2 * plane + destination] = Float(pixels[source + 2]) / 255
                }
            }
        }
        return array
    }

    // MARK: - Output

    /// Turns four heatmaps into a quad, or nil if any corner is unconvincing.
    static func decode(_ heatmaps: MLMultiArray) -> (DocumentQuad, Float)? {
        let shape = heatmaps.shape.map(\.intValue)
        guard shape.count == 4, shape[1] == 4 else { return nil }
        let height = shape[2], width = shape[3]

        var points: [CGPoint] = []
        var weakest = Float.greatestFiniteMagnitude

        heatmaps.withUnsafeBufferPointer(ofType: Float.self) { buffer in
            for corner in 0..<4 {
                let plane = corner * height * width

                var peak: Float = 0
                var peakIndex = 0
                for index in 0..<(height * width) where buffer[plane + index] > peak {
                    peak = buffer[plane + index]
                    peakIndex = index
                }
                weakest = min(weakest, peak)

                // Refine with an intensity-weighted mean of the peak's
                // neighbourhood. A bare argmax quantises the corner to the
                // heatmap's grid, which at 128 cells across a 4000-pixel
                // photograph is a visible error.
                let peakRow = peakIndex / width
                let peakColumn = peakIndex % width
                var massX: Float = 0, massY: Float = 0, mass: Float = 0
                for row in max(0, peakRow - refinementRadius)...min(height - 1, peakRow + refinementRadius) {
                    for column in max(0, peakColumn - refinementRadius)...min(width - 1, peakColumn + refinementRadius) {
                        let value = buffer[plane + row * width + column]
                        massX += value * Float(column)
                        massY += value * Float(row)
                        mass += value
                    }
                }
                let x = mass > 0 ? massX / mass : Float(peakColumn)
                let y = mass > 0 ? massY / mass : Float(peakRow)

                // Vision's normalised space has its origin at the bottom left;
                // the heatmap's is at the top.
                points.append(CGPoint(
                    x: CGFloat(x) / CGFloat(width),
                    y: 1 - CGFloat(y) / CGFloat(height)
                ))
            }
        }

        guard points.count == 4, weakest >= confidenceThreshold else { return nil }
        return (
            DocumentQuad(
                topLeft: points[0], topRight: points[1],
                bottomRight: points[2], bottomLeft: points[3]
            ),
            weakest
        )
    }
}

public extension CoreMLCornerDetector {
    /// Loads the detector from a compiled model in a bundle.
    ///
    /// Returns nil rather than throwing: a missing optional detector should
    /// quietly leave the other candidate sources to do the work, never break
    /// scanning.
    static func bundled(
        named name: String = "DocumentCorners",
        in bundle: Bundle = .main
    ) -> CoreMLCornerDetector? {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else { return nil }
        return CoreMLCornerDetector(model: model)
    }

    /// Compiles a model package at a path and loads it. Used by the evaluation
    /// harness, which has no app bundle to read from.
    static func compiling(at url: URL) throws -> CoreMLCornerDetector {
        CoreMLCornerDetector(model: try MLModel(contentsOf: MLModel.compileModel(at: url)))
    }
}
