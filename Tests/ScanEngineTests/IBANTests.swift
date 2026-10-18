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
    // Here the 7 of the example IBAN is read as S, and its check digits still
    // hold: a letter counts as two digits (S is 28), so the number changes
    // length, and mod 97 lets about 1 in 110 such misreads through. The
    // country's format does not: after "DE", a German IBAN holds only digits.
    #expect(!IBAN.isValid("DE89 3S04 0044 0532 0130 00"))
}

@Test("A letter where a digit belongs, a digit where a letter belongs, or a lost or doubled character fails the check")
func everyFormatMistakeIsCaught() {
    for example in ["DE89370400440532013000", "GB29NWBK60161331926819"] {
        let iban = Array(example)
        for index in iban.indices {
            for other in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" where other.isNumber != iban[index].isNumber {
                var misread = iban
                misread[index] = other
                #expect(!IBAN.isValid(String(misread)), "\(String(misread))")
            }
            var lost = iban
            lost.remove(at: index)
            #expect(!IBAN.isValid(String(lost)), "\(String(lost))")
            var doubled = iban
            doubled.insert(iban[index], at: index)
            #expect(!IBAN.isValid(String(doubled)), "\(String(doubled))")
        }
    }
}

@Test("The example IBAN of every country in the registry passes", arguments: [
    "AD1200012030200359100100", "AE070331234567890123456", "AL47212110090000000235698741",
    "AT611904300234573201", "AZ21NABZ00000000137010001944", "BA391290079401028494",
    "BE68539007547034", "BG80BNBG96611020345678", "BH67BMAG00001299123456",
    "BI4210000100010000332045181", "BR6699999A03000010009795493C1",
    "BY13NBRB3600900000002Z00AB00", "CH9300762011623852957", "CR05015202001026284066",
    "CY17002001280000001200527600", "CZ6508000000192000145399", "DE89370400440532013000",
    "DJ2100010000000154000100186", "DK5000400440116243", "DO28BAGR00000001212453611324",
    "EE382200221020145685", "EG380019000500000000263180002", "ES9121000418450200051332",
    "FI2112345600000785", "FK88SC123456789012", "FO6264600001631634",
    "FR1420041010050500013M02606", "GB29NWBK60161331926819", "GE29NB0000000101904917",
    "GI75NWBK000000007099453", "GL8964710001000206", "GR1601101250000000012300695",
    "GT82TRAJ01020000001210029690", "HN88CABF00000000000250005469", "HR1210010051863000160",
    "HU42117730161111101800000000", "IE29AIBK93115212345678", "IL620108000000099999999",
    "IQ98NBIQ850123456789012", "IS140159260076545510730339", "IT60X0542811101000000123456",
    "JO94CBJO0010000000000131000302", "KW81CBKU0000000000001234560101", "KZ86125KZT5004100100",
    "LB62099900000001001901229114", "LC55HEMM000100010012001200023015", "LI21088100002324013AA",
    "LT121000011101001000", "LU280019400644750000", "LV80BANK0000435195001",
    "LY83002048000020100120361", "MC5811222000010123456789030", "MD24AG000225100013104168",
    "ME25505000012345678951", "MK07250120000058984", "MN121234123456789123",
    "MR1300020001010000123456753", "MT84MALT011000012345MTLCAST001S",
    "MU17BOMM0101101030300200000MUR", "NI45BAPR00000013000003558124", "NL91ABNA0417164300",
    "NO9386011117947", "OM810180000001299123456", "PK36SCBL0000001123456702",
    "PL61109010140000071219812874", "PS92PALS000000000400123456702", "PT50000201231234567890154",
    "QA58DOHB00001234567890ABCDEFG", "RO49AAAA1B31007593840000", "RS35260005601001611379",
    "RU0304452522540817810538091310419", "SA0380000000608010167519",
    "SC18SSCB11010000000000001497USD", "SD2129010501234001", "SE4550000000058398257466",
    "SI56263300012039086", "SK3112000000198742637541", "SM86U0322509800000000270100",
    "SO211000001001000100141", "ST23000100010051845310146", "SV62CENR00000000000000700025",
    "TL380080012345678910157", "TN5910006035183598478831", "TR330006100519786457841326",
    "UA213223130000026007233566001", "VA59001123000012345678", "VG96VPVG0000012345678901",
    "XK051212012345678906", "YE15CBYE0001018861234567891234"
])
func registryExamplesAreValid(_ iban: String) {
    // The example SWIFT's IBAN registry prints for each of its 89 countries
    // (text version of 17 September 2026). A country whose format was copied
    // wrong would fail here, and its real IBANs would never be found.
    #expect(IBAN.isValid(iban))
    #expect(IBAN.find(in: "IBAN: \(iban)").count == 1)
}

@Test("A code the registry does not list, such as a creditor reference's RF, is not taken for an IBAN")
func unknownCountryIsRejected() {
    // RF is no country: it starts an ISO 11649 creditor reference, printed on
    // bills for the payer to quote. Its check digits work like an IBAN's, so
    // they hold; this is the standard's own example.
    #expect(!IBAN.isValid("RF18 5390 0754 7034"))
    #expect(IBAN.find(in: "Verwendungszweck: RF18 5390 0754 7034").isEmpty)
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
