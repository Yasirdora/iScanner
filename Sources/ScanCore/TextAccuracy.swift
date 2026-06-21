import Foundation

/// Accuracy metrics for recognised text.
///
/// These live in the engine rather than the harness so that the app can score
/// itself in the field — a page whose recognition confidence and internal
/// agreement are both low is one worth offering to rescan.
public enum TextAccuracy {

    /// Levenshtein distance, computed on two rolling rows rather than a full
    /// matrix: a dense page runs to a few thousand characters and the square
    /// matrix would be tens of megabytes for no benefit.
    public static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character error rate against a known transcript, in [0, ∞).
    ///
    /// Whitespace is collapsed on both sides first. Line breaks depend on how
    /// the recogniser chose to group the page, and charging a correct reading
    /// for wrapping differently would make this measure layout rather than
    /// accuracy.
    public static func characterErrorRate(recognized: String, truth: String) -> Double {
        let a = normalized(truth)
        let b = normalized(recognized)
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        return Double(editDistance(a, b)) / Double(a.count)
    }

    private static func normalized(_ text: String) -> [Character] {
        Array(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }
}
