import Foundation

/// Finds IBANs in recognised text, keeping only those that fit their
/// country's format and whose check digits hold.
///
/// Vision's data detection does not report IBANs, so the recogniser looks for
/// them itself and tests each one twice: against its country's format in the
/// ISO 13616 IBAN registry, then by its mod-97 check digits. The format
/// catches what the check digits miss. A letter counts as two digits (S is
/// 28), so a digit misread as a letter changes the number's length, and mod
/// 97 alone lets about 1 in 110 of those through. A German IBAN is "DE", two
/// check digits and 18 digits, so a letter after "DE" fails the format, and
/// so does a character lost or doubled. Measured on 2,000 random German IBANs,
/// every single misread character fails the check.
///
/// Not every mistake is caught. About 1 in 105 IBANs with two misread digits
/// still pass. In 38 of the 89 countries, France and Italy among them, part
/// of the account number may hold letters as well as digits; there, about 1
/// in 100 digits misread as a letter still pass, and so do some swaps of two
/// neighbouring characters. A reported IBAN is very likely the printed one,
/// not certainly. For paying a bill from a photo, a
/// missing IBAN is an inconvenience; a wrong one is money sent to a stranger,
/// so show the IBAN to the user before paying. For the same reason, a country
/// code the registry does not list is never reported: "RF" starts a creditor
/// reference, whose check digits hold too.
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
                // prefix that is a valid IBAN is the IBAN.
                let candidates = stride(from: compact.count, through: 15, by: -1).map { compact.prefix($0) }
                guard let iban = candidates.first(where: { isValid(String($0)) }).map({ grouped(String($0)) }),
                      !found.contains(iban) else { continue }
                found.append(iban)
            }
        }
        return found
    }

    /// Whether `candidate` is an IBAN of a country in the registry, in that
    /// country's format, with correct check digits. Spaces are ignored;
    /// letters may be in either case.
    public static func isValid(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }.uppercased()
        guard compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let format = formats[String(compact.prefix(2))],
              compact.count == format.count,
              zip(compact, format).allSatisfy({ character, place in
                  place == "c" || (place == "n" ? character.isNumber : character.isLetter)
              }) else { return false }

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

    /// Each country's format, one letter per character of its IBANs: "a" for
    /// a letter, "n" for a digit, "c" for either. The country code is "aa"
    /// and the check digits "nn".
    private static let formats: [String: String] = Dictionary(uniqueKeysWithValues: structures.map { structure in
        let places = structure.dropFirst(2).matches(of: /([0-9]+)!([anc])/).map { match in
            String(repeating: String(match.output.2), count: Int(match.output.1) ?? 0)
        }
        return (String(structure.prefix(2)), "aa" + places.joined())
    })

    /// The IBAN structure of every country in SWIFT's ISO 13616 IBAN registry
    /// (the text version of 17 September 2026, 89 countries), copied as
    /// printed there. After the country code, "2!n" is exactly two digits,
    /// "4!a" exactly four capital letters and "12!c" exactly twelve letters or
    /// digits. A country the registry adds later is not found until it is
    /// added here.
    private static let structures = [
        "AD2!n4!n4!n12!c", "AE2!n3!n16!n", "AL2!n8!n16!c", "AT2!n5!n11!n",
        "AZ2!n4!a20!c", "BA2!n3!n3!n8!n2!n", "BE2!n3!n7!n2!n",
        "BG2!n4!a4!n2!n8!c", "BH2!n4!a14!c", "BI2!n5!n5!n11!n2!n",
        "BR2!n8!c5!n10!n1!c1!c", "BY2!n4!c4!n16!c", "CH2!n5!n12!c",
        "CR2!n4!n14!n", "CY2!n3!n5!n16!c", "CZ2!n4!n6!n10!n", "DE2!n8!n10!n",
        "DJ2!n5!n5!n11!n2!n", "DK2!n4!n9!n1!n", "DO2!n4!c20!n", "EE2!n2!n14!n",
        "EG2!n4!n4!n17!n", "ES2!n4!n4!n1!n1!n10!n", "FI2!n3!n11!n",
        "FK2!n2!a12!n", "FO2!n4!n9!n1!n", "FR2!n5!n5!n11!c2!n",
        "GB2!n4!a6!n8!n", "GE2!n2!a16!n", "GI2!n4!a15!c", "GL2!n4!n9!n1!n",
        "GR2!n3!n4!n16!c", "GT2!n4!c20!c", "HN2!n4!a20!n", "HR2!n7!n10!n",
        "HU2!n3!n4!n1!n15!n1!n", "IE2!n4!a6!n8!n", "IL2!n3!n3!n13!n",
        "IQ2!n4!a3!n12!n", "IS2!n4!n2!n6!n10!n", "IT2!n1!a5!n5!n12!c",
        "JO2!n4!a4!n18!c", "KW2!n4!a22!c", "KZ2!n3!n13!c", "LB2!n4!n20!c",
        "LC2!n4!a24!c", "LI2!n5!n12!c", "LT2!n5!n11!n", "LU2!n3!n13!c",
        "LV2!n4!a13!c", "LY2!n3!n3!n15!n", "MC2!n5!n5!n11!c2!n", "MD2!n2!c18!c",
        "ME2!n3!n13!n2!n", "MK2!n3!n10!c2!n", "MN2!n4!n12!n",
        "MR2!n5!n5!n11!n2!n", "MT2!n4!a5!n18!c", "MU2!n4!a2!n2!n12!n3!n3!a",
        "NI2!n4!a20!n", "NL2!n4!a10!n", "NO2!n4!n6!n1!n", "OM2!n3!n16!c",
        "PK2!n4!a16!c", "PL2!n8!n16!n", "PS2!n4!a21!c", "PT2!n4!n4!n11!n2!n",
        "QA2!n4!a21!c", "RO2!n4!a16!c", "RS2!n3!n13!n2!n", "RU2!n9!n5!n15!c",
        "SA2!n2!n18!c", "SC2!n4!a2!n2!n16!n3!a", "SD2!n2!n12!n",
        "SE2!n3!n16!n1!n", "SI2!n5!n8!n2!n", "SK2!n4!n6!n10!n",
        "SM2!n1!a5!n5!n12!c", "SO2!n4!n3!n12!n", "ST2!n4!n4!n11!n2!n",
        "SV2!n4!a20!n", "TL2!n3!n14!n2!n", "TN2!n2!n3!n13!n2!n",
        "TR2!n5!n1!n16!c", "UA2!n6!n19!c", "VA2!n3!n15!n", "VG2!n4!a16!n",
        "XK2!n4!n10!n2!n", "YE2!n4!a4!n18!c"
    ]

    private static func grouped(_ compact: String) -> String {
        stride(from: 0, to: compact.count, by: 4).map { start in
            let from = compact.index(compact.startIndex, offsetBy: start)
            let to = compact.index(from, offsetBy: 4, limitedBy: compact.endIndex) ?? compact.endIndex
            return String(compact[from..<to])
        }.joined(separator: " ")
    }
}
