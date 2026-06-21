import CoreGraphics
import Foundation

/// A learned model that proposes the four corners of a document.
///
/// Declared here and implemented by the app, because the engine has no opinion
/// about how a model is loaded and the app is where Core ML compiles its
/// assets. `DocumentCandidateSelector` treats whatever arrives through this as
/// one more candidate to rank, never as the answer — a model that is confidently
/// wrong should lose to a heuristic that is right, and the scorer is what
/// decides that.
public protocol DocumentCornerPredicting: Sendable {
    /// The corners the model proposes, with its own confidence, or nil when it
    /// finds nothing it believes in.
    func corners(in image: CGImage) async -> (quad: DocumentQuad, confidence: Float)?
}
