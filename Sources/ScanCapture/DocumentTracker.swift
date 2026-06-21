import Foundation
import CoreGraphics

/// Combines a cheap per-frame reading with an occasional expensive one.
///
/// The two detectors available have very different costs and very different
/// strengths. Vision's segmenter runs in single-digit milliseconds and finds a
/// page that fills the frame, but returns nothing at all for a small card lying
/// on a larger sheet. The candidate selector finds that card reliably and costs
/// around 150 ms on a desktop, so it cannot run on the frame path.
///
/// This holds the result of both and decides which to believe. The expensive
/// reading wins while it is fresh and while the scene still looks like the one
/// it was taken from; otherwise the cheap one carries the viewfinder. That way
/// the outline stays responsive to movement without losing the only detector
/// that can see a small item.
///
/// Pure and synchronous: it takes readings and a clock and returns a quad, with
/// no camera and no scheduling of its own, so every rule here is directly
/// testable.
public struct DocumentTracker: Sendable {

    public struct Configuration: Sendable {
        /// How long an expensive reading is trusted after it was taken.
        ///
        /// Long enough to survive the gap between passes, short enough that a
        /// page which has been moved away stops being reported.
        public var preciseLifetime: Double = 2.0

        /// How long a cheap reading is trusted. Roughly a handful of frames:
        /// the point is only to bridge a detector that blinks, not to keep
        /// drawing an outline over an empty table.
        public var fastLifetime: Double = 0.4

        /// How far the cheap reading may drift from where it sat when the
        /// expensive reading was taken before that reading is treated as
        /// describing a scene that no longer exists.
        public var sceneChangeDrift: Double = 0.18

        public init() {}
    }

    private struct Reading {
        var quad: DocumentQuad
        var timestamp: Double
    }

    public var configuration: Configuration

    private var fast: Reading?
    private var precise: Reading?
    /// Where the cheap detector was looking when the expensive reading landed,
    /// used to notice that the scene has since changed.
    private var fastAtPreciseTime: DocumentQuad?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func record(fast quad: DocumentQuad?, at timestamp: Double) {
        self.fast = quad.map { Reading(quad: $0, timestamp: timestamp) }
    }

    /// Records an expensive reading. A failed pass is *not* a reading.
    ///
    /// Overwriting the last good outline with nothing is what made the box
    /// disappear the moment the phone moved: motion blurs the print, the
    /// detector finds no text, and the outline it had a moment ago was erased
    /// rather than simply not updated. A failure now leaves the previous
    /// reading in place to expire on its own clock.
    public mutating func record(precise quad: DocumentQuad?, at timestamp: Double) {
        guard let quad else { return }
        precise = Reading(quad: quad, timestamp: timestamp)
        fastAtPreciseTime = fast?.quad
    }

    /// Clears the expensive reading outright, for when the page is known to be
    /// gone rather than merely unfound this pass.
    public mutating func invalidatePrecise() {
        precise = nil
        fastAtPreciseTime = nil
    }

    /// The outline to show, or nil when nothing recent is worth drawing.
    public func quad(at now: Double) -> DocumentQuad? {
        let liveFast = fast.flatMap { now - $0.timestamp <= configuration.fastLifetime ? $0 : nil }
        let livePrecise = precise.flatMap { now - $0.timestamp <= configuration.preciseLifetime ? $0 : nil }

        guard let livePrecise else { return liveFast?.quad }

        // If the cheap detector has moved a long way since the expensive
        // reading was taken, the phone has been pointed somewhere else and the
        // expensive answer describes a scene that is gone.
        if let liveFast, let reference = fastAtPreciseTime,
           liveFast.quad.maximumCornerDrift(from: reference) > configuration.sceneChangeDrift {
            return liveFast.quad
        }
        return livePrecise.quad
    }

    /// True while an expensive reading is the one being shown — the viewfinder
    /// uses this to say it has locked onto a small item rather than the sheet
    /// underneath it.
    public func isPrecise(at now: Double) -> Bool {
        guard let precise, now - precise.timestamp <= configuration.preciseLifetime else { return false }
        guard let fast, let reference = fastAtPreciseTime else { return true }
        return fast.quad.maximumCornerDrift(from: reference) <= configuration.sceneChangeDrift
    }

    public mutating func reset() {
        fast = nil
        precise = nil
        fastAtPreciseTime = nil
    }
}
