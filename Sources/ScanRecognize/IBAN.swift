import Foundation

/// Finds IBANs in recognised text, keeping only those whose check digits hold.
///
/// Vision's data detection does not report IBANs, so the recogniser looks for
/// them itself. The check digits do the real work: under the ISO 13616 mod-97
/// test, one misread character makes an IBAN invalid, so a reported IBAN was
/// either read correctly or is not reported at all. For paying a bill from a
/// photo, a missing IBAN is an inconvenience; a wrong one is money sent to a
/// stranger.
public enum IBAN {

    /// IBANs in `text`, in reading order, grouped in fours as printed on a
    /// bill: `DE89 3704 0044 0532 0130 00`.
    public static func find(in text: String) -> [String] {
        // Two letters, two check digits, then 11 to 30 letters or digits,
        // optionally broken by single spaces. Searched line by line, so an
        // IBAN never runs into the line below it.
        //
        // Simple word boundaries, not Unicode's: under the Unicode rules a
        // colon between letters joins two words, so in "IBAN:DE89…" — common
        // in OCR output — there is no boundary in front of the IBAN at all.
        let pattern = /\b[A-Za-z]{2}[0-9]{2}(?: ?[A-Za-z0-9]){11,30}\b/.wordBoundaryKind(.simple)
        var found: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            for match in line.matches(of: pattern) {
                let compact = String(match.output).filter { !$0.isWhitespace }.uppercased()
                // The pattern is greedy, so a word printed right after the
                // IBAN ("… 0130 00 BIC") can join the match. The longest
                // prefix whose check digits hold is the IBAN.
                let candidates = stride(from: compact.count, through: 15, by: -1).map { compact.prefix($0) }
                guard let iban = candidates.first(where: { isValid(String($0)) }).map({ grouped(String($0)) }),
                      !found.contains(iban) else { continue }
                found.append(iban)
            }
        }
        return found
    }

    /// Whether `candidate` is a well-formed IBAN with correct check digits.
    /// Spaces are ignored; letters may be in either case.
    public static func isValid(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count),
              compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              compact.prefix(2).allSatisfy(\.isLetter),
              compact.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }

        // Move the country code and check digits to the end, turn letters into
        // numbers (A = 10 … Z = 35), and the whole must leave remainder 1
        // when divided by 97. Done digit by digit: the number has up to 70.
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let value = character.isNumber
                ? character.wholeNumberValue
                : character.asciiValue.map({ Int($0) - 55 }) else { return false }
            for digit in String(value) {
                remainder = (remainder * 10 + (digit.wholeNumberValue ?? 0)) % 97
            }
        }
        return remainder == 1
    }

    private static func grouped(_ compact: String) -> String {
        stride(from: 0, to: compact.count, by: 4).map { start in
            let from = compact.index(compact.startIndex, offsetBy: start)
            let to = compact.index(from, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
            return String(compact[from..<to])
        }.joined(separator: " ")
    }
}
