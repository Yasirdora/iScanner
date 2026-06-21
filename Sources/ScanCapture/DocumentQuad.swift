import Foundation
import CoreGraphics

/// A detected page outline, in normalised image coordinates with the origin at
/// the lower left, matching Vision.
public struct DocumentQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Fraction of the frame the page covers, by the shoelace formula.
    public var area: Double {
        let points = corners
        var sum = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    public var boundingBox: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Largest distance any single corner moved between two detections.
    ///
    /// This is the motion signal the stabiliser runs on. Comparing bounding
    /// boxes or areas would miss a page rotating or tilting in place, which is
    /// exactly the movement that produces a keystoned capture — the corners
    /// swing while the box barely changes.
    public func maximumCornerDrift(from other: DocumentQuad) -> Double {
        zip(corners, other.corners)
            .map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }
            .max() ?? 0
    }

    /// How far from rectangular the quad is, as the larger of the two
    /// opposite-edge length ratios minus one.
    ///
    /// A page shot square-on has equal opposite edges. Steep perspective makes
    /// one pair diverge, and rectifying that costs resolution and sharpness at
    /// the far edge, so it is worth asking the user to move rather than
    /// capturing and fixing it afterwards.
    public var skew: Double {
        func length(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double(a.x - b.x), Double(a.y - b.y))
        }
        let top = length(topLeft, topRight)
        let bottom = length(bottomLeft, bottomRight)
        let left = length(topLeft, bottomLeft)
        let right = length(topRight, bottomRight)

        let horizontal = max(top, bottom) / max(min(top, bottom), 1e-6)
        let vertical = max(left, right) / max(min(left, right), 1e-6)
        return max(horizontal, vertical) - 1
    }

    /// Whether a point lies inside the quad, by the ray-crossing test.
    ///
    /// A rotated quad's bounding box can be nearly twice its area, so testing
    /// against the box counts content that is plainly outside the page. On a
    /// voucher lying at forty degrees that was enough to make a small rectangle
    /// printed *on* it appear to contain the voucher's text.
    public func contains(_ point: CGPoint) -> Bool {
        let points = corners
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > point.y) != (b.y > point.y) {
                let slope = (b.x - a.x) / (b.y - a.y)
                if point.x < a.x + slope * (point.y - a.y) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Bounding-box intersection over union. Used only to decide whether a new
    /// detection is the same page as the last one captured, where the coarse
    /// answer is the right one.
    public func intersectionOverUnion(_ other: DocumentQuad) -> Double {
        let a = boundingBox, b = other.boundingBox
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - overlap
        guard union > 0 else { return 0 }
        return overlap / union
    }
}
