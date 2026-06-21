import CoreGraphics
import Foundation
import Vision

/// Follows a known page outline from frame to frame.
///
/// Detection alone cannot keep an outline glued to a moving page. The detector
/// that finds a small item costs too much to run per frame, so between its
/// passes the outline is either frozen where the page used to be or gone
/// entirely — and a page in motion is blurred, so the next pass often finds
/// nothing and the outline vanishes exactly when the user is moving.
///
/// Tracking closes that gap. Vision follows an outline it has already been
/// given far more cheaply than it can find one, so the expensive detector runs
/// occasionally to say *what* to follow and this keeps up with *where* it is.
///
/// A class rather than a struct because tracking is inherently stateful — each
/// result seeds the next frame's request — and that reads badly through
/// `mutating async`. Main-actor bound because it belongs to a live capture
/// session and is only ever driven from one: the sequence of frames is the
/// state, so sharing it across tasks would corrupt the very thing it tracks.
@MainActor
public final class QuadTracker {

    /// Vision's own tracking, at its cheaper level. Accuracy here only has to
    /// hold until the next full detection re-seeds it.
    private static let level: TrackRectangleRequest.TrackingLevel = .fast

    private var observation: RectangleObservation?

    public init() {}

    public var isTracking: Bool { observation != nil }

    /// Points the tracker at an outline a detector just found.
    public func seed(_ quad: DocumentQuad) {
        observation = RectangleObservation(
            topLeft: NormalizedPoint(x: quad.topLeft.x, y: quad.topLeft.y),
            topRight: NormalizedPoint(x: quad.topRight.x, y: quad.topRight.y),
            bottomRight: NormalizedPoint(x: quad.bottomRight.x, y: quad.bottomRight.y),
            bottomLeft: NormalizedPoint(x: quad.bottomLeft.x, y: quad.bottomLeft.y)
        )
    }

    public func reset() {
        observation = nil
    }

    /// Where the outline has moved to, or nil once the page can no longer be
    /// followed.
    public func track(in frame: CameraFrame) async -> DocumentQuad? {
        guard let seed = observation else { return nil }

        let request = TrackRectangleRequest(detectedRectangle: seed)
        request.trackingLevel = Self.level

        guard let result = try? await ImageRequestHandler(frame.buffer).perform(request) else {
            // Losing the page is a real answer, not a hiccup: keeping a stale
            // seed would have the tracker chase whatever happens to sit under
            // the old outline.
            observation = nil
            return nil
        }

        observation = result
        return DocumentQuad(
            topLeft: result.topLeft.cgPoint,
            topRight: result.topRight.cgPoint,
            bottomRight: result.bottomRight.cgPoint,
            bottomLeft: result.bottomLeft.cgPoint
        )
    }
}
