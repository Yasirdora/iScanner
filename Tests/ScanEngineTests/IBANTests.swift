import Testing
import ScanRecognize

// The IBAN check is pure arithmetic, so these tests need no Vision and run
// everywhere, CI included. The IBANs are the examples published for each
// country's banking documentation, not real accounts; each expected answer was
// checked against an independent mod-97 calculation.

@Test("Example IBANs pass their check digits, with or without spaces, in any case",
      arguments: ["DE89 3704 0044 0532 0130 00", "DE89370400440532013000", "de89 3704 0044 0532 0130 00", "GB82 WEST 1234 5698 7654 32"])
func exampleIBANsAreValid(_ iban: String) {
    #expect(IBAN.isValid(iban))
}

@Test("One misread character fails the check",
      arguments: ["DE89 3704 0044 0532 0130 01", "DE89 3704 0044 0532 0I30 00", "DE98 3704 0044 0532 0130 00"])
func misreadIBANsAreRejected(_ iban: String) {
    // A last digit misread, a zero read as the letter I, the check digits
    // swapped: the three mistakes OCR is most likely to make here.
    #expect(!IBAN.isValid(iban))
}

@Test("Every digit misread as another digit, and every swap of two neighbouring digits, fails the check")
func everyDigitMistakeIsCaught() {
    let iban = Array("DE89370400440532013000")
    for index in iban.indices where iban[index].isNumber {
        for digit in "0123456789" where digit != iban[index] {
            var misread = iban
            misread[index] = digit
            #expect(!IBAN.isValid(String(misread)), "\(String(misread))")
        }
        let next = index + 1
        if next < iban.count, iban[next].isNumber, iban[next] != iban[index] {
            var swapped = iban
            swapped.swapAt(index, next)
            #expect(!IBAN.isValid(String(swapped)), "\(String(swapped))")
        }
    }
}

@Test("A digit read as a letter fails the check")
func letterForDigitIsRejected() {
    // Known limit of mod 97, kept visible. A letter counts as two digits
    // (S is 28), so reading a digit as a letter changes the number's length,
    // and about 1 in 110 such misreads still leave remainder 1. Here the 7 of
    // the example IBAN is read as S, and the check still holds.
    withKnownIssue("Mod 97 lets about 1 in 110 digits read as a letter through") {
        #expect(!IBAN.isValid("DE89 3S04 0044 0532 0130 00"))
    }
}

@Test("An IBAN is found in a line of text, grouped in fours")
func ibanIsFoundInText() {
    #expect(IBAN.find(in: "IBAN: DE89 3704 0044 0532 0130 00") == ["DE89 3704 0044 0532 0130 00"])
    // Run together, and with the next field printed straight after it.
    #expect(IBAN.find(in: "IBAN:DE89370400440532013000 BIC: COBADEFFXXX") == ["DE89 3704 0044 0532 0130 00"])
}

@Test("A VAT number, an invoice number or a phone number is not taken for an IBAN")
func otherNumbersAreNotIBANs() {
    let text = """
    USt-IdNr. DE123456789
    RECHNUNG Nr. RE-2026-0815
    Tel. +49 30 1234567
    """
    #expect(IBAN.find(in: text).isEmpty)
}

@Test("An IBAN printed twice is reported once")
func ibanIsReportedOnce() {
    let text = "IBAN: DE89 3704 0044 0532 0130 00\nBitte an DE89370400440532013000 überweisen."
    #expect(IBAN.find(in: text) == ["DE89 3704 0044 0532 0130 00"])
}
