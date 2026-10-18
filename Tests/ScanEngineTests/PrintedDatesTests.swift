import Testing
@testable import ScanRecognize

// Data detection completes dates from the day it runs on. These tests check
// that only dates printed in the text are reported. They read text, not
// images, so they need no Vision.
//
// Dates are compared by their day: the values are in UTC, and a date with no
// time is noon in this Mac's time zone, so the time part depends on the zone.

/// The day of each date found in `text`, such as "2026-10-28".
private func days(in text: String) async -> [String] {
    await PrintedDates.find(in: text).map { String($0.prefix(10)) }
}

@Test("A date after 'bis' or 'until' is reported, and the day of the reading is not")
func untilGivesItsLastDay() async {
    // Regression: data detection reads "bis 28.10.2026" as a span from the day
    // it runs on to 28 October. Only the span's first day was reported, so a
    // scanned bill showed the day of the scan and lost its due date.
    let german = await days(in: "Zahlbar bis 28.10.2026 ohne Abzug.")
    let english = await days(in: "Payable until October 28, 2026")
    #expect(german == ["2026-10-28"])
    #expect(english == ["2026-10-28"])
}

@Test("A printed span gives both of its days")
func spanGivesBothDays() async {
    let found = await days(in: "Leistungszeitraum: vom 10.10.2026 bis 14.10.2026")
    #expect(found == ["2026-10-10", "2026-10-14"])
}

@Test("A time, a weekday, 'heute' or a date without a year gives no date",
      arguments: ["14:35", "Mo 14:35", "Öffnungszeiten 9:00 - 18:00", "heute", "morgen", "Montag", "bis 28. Oktober"])
func incompleteDatesAreNotReported(_ text: String) async {
    // Each of these comes back from data detection as a date near the day it
    // runs on. None of them is a date printed on the page.
    let found = await days(in: text)
    #expect(found.isEmpty, "'\(text)' gave \(found)")
}

@Test("Printed dates are kept, with or without a time, in reading order")
func printedDatesAreKept() async {
    let text = """
    Rechnungsdatum: 14.10.2026
    Leistungsdatum: 10.10.2026
    2026-08-14  14:32
    Datum 28.10.26
    """
    let found = await days(in: text)
    #expect(found == ["2026-10-14", "2026-10-10", "2026-08-14", "2026-10-28"])
}
