import Foundation
import CoreGraphics

/// Adaptive low-pass filter: heavy smoothing when a value is nearly still,
/// light smoothing when it is moving fast.
///
/// A plain exponential average forces a choice between a jittery overlay and a
/// laggy one. This varies its cutoff with the observed speed, so a resting page
/// gets aggressive smoothing while a page being moved is tracked with almost no
/// delay. It is the standard filter for exactly this problem — jittery
/// per-frame estimates driving something a person is looking at.
struct OneEuroFilter {
    /// Cutoff at rest, in Hz. Lower means steadier and slower to respond.
    var minimumCutoff: Double = 0.9
    /// How much speed raises the cutoff. Higher means less lag when moving.
    ///
    /// 0.7 is the only value in a sweep from 0.35 to 3.0 where both properties
    /// hold: below it the outline lags a moving page, above it the filter stops
    /// suppressing a still page's jitter by the required margin.
    var speedCoefficient: Double = 0.7
    /// Cutoff for the speed estimate itself.
    var derivativeCutoff: Double = 1.0

    private var previousValue: Double?
    private var previousSpeed: Double = 0

    mutating func apply(_ value: Double, timeStep: Double) -> Double {
        guard timeStep > 0, let previous = previousValue else {
            previousValue = value
            return value
        }

        let rawSpeed = (value - previous) / timeStep
        let speed = lowPass(rawSpeed, previous: previousSpeed, cutoff: derivativeCutoff, timeStep: timeStep)
        previousSpeed = speed

        let cutoff = minimumCutoff + speedCoefficient * abs(speed)
        let smoothed = lowPass(value, previous: previous, cutoff: cutoff, timeStep: timeStep)
        previousValue = smoothed
        return smoothed
    }

    mutating func reset() {
        previousValue = nil
        previousSpeed = 0
    }

    private func lowPass(_ value: Double, previous: Double, cutoff: Double, timeStep: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        let alpha = 1 / (1 + tau / timeStep)
        return alpha * value + (1 - alpha) * previous
    }
}

/// Smooths a detected page outline for display.
///
/// Vision returns a slightly different quad on every frame even when nothing
/// moves. Drawn raw, the outline shimmers and snaps around the page. Filtering
/// each of the eight coordinates independently removes that without noticeably
/// delaying the outline when the phone is actually moved.
public struct QuadSmoother: Sendable {

    /// How long a detection dropout is tolerated before the outline is dropped.
    ///
    /// The detector misses the occasional frame — a blink of motion blur, a
    /// hand crossing the page. Removing the outline for a single frame and
    /// putting it straight back is far more visible than briefly showing a
    /// slightly stale one.
    public var dropoutGrace: Double = 0.35

    private var filters = [OneEuroFilter](repeating: OneEuroFilter(), count: 8)
    private var lastUpdate: Double?
    private var lastQuad: DocumentQuad?
    private var lastSeen: Double = -.infinity

    public init() {}

    /// Returns the outline to draw, or nil once the grace period has expired.
    public mutating func smooth(_ quad: DocumentQuad?, now: Double) -> DocumentQuad? {
        guard let quad else {
            guard now - lastSeen < dropoutGrace else {
                reset()
                return nil
            }
            return lastQuad
        }

        let timeStep = lastUpdate.map { now - $0 } ?? 1.0 / 30
        lastUpdate = now
        lastSeen = now

        var values = quad.corners.flatMap { [Double($0.x), Double($0.y)] }
        for index in values.indices {
            values[index] = filters[index].apply(values[index], timeStep: timeStep)
        }

        let smoothed = DocumentQuad(
            topLeft: CGPoint(x: values[0], y: values[1]),
            topRight: CGPoint(x: values[2], y: values[3]),
            bottomRight: CGPoint(x: values[4], y: values[5]),
            bottomLeft: CGPoint(x: values[6], y: values[7])
        )
        lastQuad = smoothed
        return smoothed
    }

    public mutating func reset() {
        filters = [OneEuroFilter](repeating: OneEuroFilter(), count: 8)
        lastUpdate = nil
        lastQuad = nil
        lastSeen = -.infinity
    }
}
