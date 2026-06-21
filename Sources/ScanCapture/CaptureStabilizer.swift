import Foundation

/// What the viewfinder should be telling the user right now.
public enum CaptureGuidance: Equatable, Sendable {
    case searching
    case moveCloser
    case flatten
    case holdSteady(progress: Double)
    case captured
    case awaitingNextPage
}

public struct CaptureDecision: Equatable, Sendable {
    public var guidance: CaptureGuidance
    public var shouldCapture: Bool
}

public struct StabilizerConfiguration: Sendable {
    /// Consecutive settled frames required before firing. At 30 fps this is
    /// about a quarter of a second — long enough that a hand coming to rest has
    /// actually stopped, short enough not to feel sluggish.
    public var requiredStableFrames: Int = 8

    /// Largest corner movement, in normalised units per frame, still counted
    /// as settled.
    ///
    /// This is deliberately tight. At 30 fps, 0.0035 is about a tenth of the
    /// frame per second — the scale of hand tremor on a braced phone, and
    /// forgiving enough that a steady hand triggers reliably. An earlier value
    /// of 0.012 admitted a third of the frame per second, which is not a
    /// tremor, it is a deliberate movement, and it fires the shutter mid-swing.
    /// That is what produces a keystoned frame alongside a good one.
    public var maximumCornerDrift: Double = 0.0035

    /// Largest frame-to-frame area change still counted as settled. Catches the
    /// phone moving toward or away from the page, which barely shifts corners
    /// relative to each other but changes scale.
    public var maximumAreaDelta: Double = 0.008

    /// Page must fill at least this fraction of the frame. Below it there are
    /// too few pixels per character for recognition to be reliable.
    public var minimumArea: Double = 0.15

    /// Largest opposite-edge ratio deviation accepted before asking the user to
    /// square up rather than capturing a steep perspective.
    public var maximumSkew: Double = 0.38

    public var minimumConfidence: Float = 0.5

    /// Quiet period after a capture, so the shutter cannot fire twice on one
    /// gesture.
    public var cooldownSeconds: Double = 1.0

    /// Overlap with the page just captured, above which a detection is treated
    /// as the same page still sitting there rather than a new one.
    public var newPageMaximumOverlap: Double = 0.55

    public init() {}
}

/// Decides when the shutter should fire.
///
/// VisionKit's built-in scanner makes this decision itself and exposes no way
/// to influence it, which is how one page ends up captured twice — once part
/// way through the movement and once after it settles. This replaces that with
/// two explicit rules:
///
/// 1. **Settle before firing.** The page must hold still, by corner drift and
///    by area, for a run of consecutive frames. A page that is still moving is
///    a page that will be captured keystoned or motion-blurred.
/// 2. **Re-arm deliberately.** After a capture the shutter locks out for a
///    cooldown, and then stays locked until the page either leaves the frame or
///    is replaced by one that overlaps it little enough to be a different
///    sheet. Holding the phone over the same page cannot produce a second shot.
///
/// The type is pure: it takes detections and a timestamp and returns a
/// decision, with no camera or clock of its own, so every rule above is
/// directly testable.
public struct CaptureStabilizer: Sendable {

    public var configuration: StabilizerConfiguration

    private var stableFrames = 0
    private var previous: DocumentQuad?
    private var lastCaptured: DocumentQuad?
    private var lockedUntil: Double = -.infinity
    private var awaitingNewPage = false

    public init(configuration: StabilizerConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Feed one frame's detection. `now` is a monotonic time in seconds.
    public mutating func update(
        quad: DocumentQuad?,
        confidence: Float,
        now: Double
    ) -> CaptureDecision {
        guard let quad, confidence >= configuration.minimumConfidence else {
            // Losing the page is the clearest possible signal that whatever was
            // captured is finished with, so it re-arms immediately.
            reset()
            awaitingNewPage = false
            lastCaptured = nil
            return CaptureDecision(guidance: .searching, shouldCapture: false)
        }

        if now < lockedUntil {
            previous = quad
            return CaptureDecision(guidance: .captured, shouldCapture: false)
        }

        if awaitingNewPage {
            let overlap = lastCaptured.map { quad.intersectionOverUnion($0) } ?? 0
            guard overlap < configuration.newPageMaximumOverlap else {
                previous = quad
                return CaptureDecision(guidance: .awaitingNextPage, shouldCapture: false)
            }
            awaitingNewPage = false
            reset()
        }

        guard quad.area >= configuration.minimumArea else {
            reset()
            previous = quad
            return CaptureDecision(guidance: .moveCloser, shouldCapture: false)
        }

        guard quad.skew <= configuration.maximumSkew else {
            reset()
            previous = quad
            return CaptureDecision(guidance: .flatten, shouldCapture: false)
        }

        if let previous, isSettled(quad, against: previous) {
            stableFrames += 1
        } else {
            stableFrames = 1
        }
        previous = quad

        guard stableFrames >= configuration.requiredStableFrames else {
            let progress = Double(stableFrames) / Double(configuration.requiredStableFrames)
            return CaptureDecision(guidance: .holdSteady(progress: progress), shouldCapture: false)
        }

        lastCaptured = quad
        lockedUntil = now + configuration.cooldownSeconds
        awaitingNewPage = true
        reset()
        return CaptureDecision(guidance: .captured, shouldCapture: true)
    }

    /// Called when the user takes a shot by hand, so the automatic path does not
    /// immediately take a second one of the same page.
    public mutating func noteManualCapture(quad: DocumentQuad?, now: Double) {
        lastCaptured = quad
        lockedUntil = now + configuration.cooldownSeconds
        awaitingNewPage = quad != nil
        reset()
    }

    private func isSettled(_ quad: DocumentQuad, against previous: DocumentQuad) -> Bool {
        quad.maximumCornerDrift(from: previous) <= configuration.maximumCornerDrift
            && abs(quad.area - previous.area) <= configuration.maximumAreaDelta
    }

    private mutating func reset() {
        stableFrames = 0
        previous = nil
    }
}
