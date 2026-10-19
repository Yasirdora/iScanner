import Foundation
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

@Test("A date written with dots is read day first, whatever the device's region",
      arguments: [
          ("Rechnungsdatum: 01.10.2026", ["2026-10-01"]),
          ("Leistungszeitraum 01.10.2026 - 10.10.2026", ["2026-10-01", "2026-10-10"]),
          ("Leistungszeitraum: vom 05.11.2026 bis 02.12.2026", ["2026-11-05", "2026-12-02"]),
          ("Zahlbar bis 01.10.2026", ["2026-10-01"]),
          ("05.11.26", ["2026-11-05"]),
          ("Lieferdatum 5.11.99", ["1999-11-05"]),
      ])
func dottedDatesAreDayFirst(_ text: String, _ expected: [String]) async {
    // Regression: data detection takes the order of day and month from the
    // device's region. With the region set to the United States, "01.10.2026"
    // came back as 10 January, and the span to "02.12.2026" ended on
    // 12 February 2027. Germany and most of Europe write dates with dots day
    // first. These fail without the fix only on a Mac whose region is the
    // United States.
    let found = await days(in: text)
    #expect(found == expected, "'\(text)' gave \(found)")
}

@Test("A date written with dots keeps its printed time")
func dottedDateKeepsItsTime() async {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let printed = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14, minute: 32))!
    let found = await PrintedDates.find(in: "Beleg 01.10.2026 14:32")
    #expect(found == [ISO8601DateFormatter().string(from: printed)])
}

@Test("Dates not written day first with dots are read as before",
      arguments: [
          ("2026-10-28", ["2026-10-28"]),
          ("Oct 28, 2026", ["2026-10-28"]),
          ("Payable until October 1, 2026", ["2026-10-01"]),
          ("28.10.2026", ["2026-10-28"]),
          // No date day first, so it can only be month first.
          ("12.31.2026", ["2026-12-31"]),
      ])
func otherDatesAreUnchanged(_ text: String, _ expected: [String]) async {
    let found = await days(in: text)
    #expect(found == expected, "'\(text)' gave \(found)")
}
