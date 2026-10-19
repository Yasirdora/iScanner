import Foundation
import DataDetection

/// Finds the dates printed in recognised text.
///
/// Data detection completes what a text leaves out from the day it runs on.
/// "Zahlbar bis 28.10.2026" ("payable until") comes back as a span from that
/// day to 28 October; a time printed on its own, a weekday or "heute" come back
/// as dates near that day; a date without a year gets that day's year. Taken as
/// they come, a scanned bill shows the day of the scan as one of its dates, and
/// the due date is lost.
///
/// A scanned page has no "today". So the text is read twice, as if on two days
/// more than a year apart, and a date is kept only when both readings give the
/// same one: then it was printed on the page, not completed from the day of
/// the reading. A span gives each end that holds, so "bis 28.10.2026" gives
/// 28 October.
///
/// Data detection also takes the order of day and month from the device's
/// region, not from the page: with the region set to the United States,
/// "01.10.2026" comes back as 10 January. Dates written with dots are day
/// first, so the day and month of such a date are taken from the text itself.
enum PrintedDates {

    /// Dates printed in `text`, in reading order, as ISO 8601 strings.
    static func find(in text: String) async -> [String] {
        let now = Date()
        let first = await readings(of: text, on: now)
        var second = await readings(of: text, on: now.addingTimeInterval(400 * 24 * 60 * 60))
        var found: [String] = []
        for reading in first {
            // Both readings are of the same string, so the same words have the
            // same range.
            guard let index = second.firstIndex(where: { $0.range == reading.range }) else { continue }
            let other = second.remove(at: index)
            // A span's first day is its first date written with dots, its
            // last day the last one.
            let written = reading.range.map { dottedDates(in: text[$0]) } ?? []
            for (end, (date, same)) in zip(reading.dates, other.dates).enumerated() where date != nil && date == same {
                let printed = end == 0 ? written.first : written.last
                found.append(ISO8601DateFormatter().string(from: dayFirst(date!, as: printed)))
            }
        }
        return found
    }

    /// Each date found in `text` when it is read on `day`: where it is, and
    /// its first and last day.
    private static func readings(
        of text: String, on day: Date
    ) async -> [(range: Range<String.Index>?, dates: [Date?])] {
        var options = DataDetector.Options()
        options.documentDate = day
        var readings: [(range: Range<String.Index>?, dates: [Date?])] = []
        for await match in text.dataDetectorMatches(.calendarEvent, options: options) {
            if case .calendarEvent(let event) = match.details {
                readings.append((match.range, [event.startDate, event.endDate]))
            }
        }
        return readings
    }

    /// A date written with dots: day, month, year.
    private struct DottedDate {
        let day: Int
        let month: Int
        /// As printed: 2026, or 26.
        let year: Int
    }

    /// The dates written with dots in `words`, such as "01.10.2026" or
    /// "1.10.26", in reading order.
    private static func dottedDates(in words: Substring) -> [DottedDate] {
        // The year comes last, with four digits or two.
        let pattern = /\b([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4}|[0-9]{2})\b/.wordBoundaryKind(.simple)
        return words.matches(of: pattern).map { match in
            DottedDate(day: Int(match.output.1)!, month: Int(match.output.2)!, year: Int(match.output.3)!)
        }
    }

    /// `date` read day first, as `printed` is written, when data detection
    /// read its day as the month and its month as the day. Any other date is
    /// returned as it is.
    ///
    /// The time of day stays data detection's. The year is the printed one:
    /// a span read the wrong way round can end a year late ("05.11.2026 -
    /// 02.12.2026" ended on 12 February 2027).
    private static func dayFirst(_ date: Date, as printed: DottedDate?) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let printed, let detected = parts.year,
              parts.month == printed.day, parts.day == printed.month else { return date }
        parts.year = year(printed.year, closestTo: detected)
        parts.month = printed.month
        parts.day = printed.day
        // "12.31.2026" is no date day first, so data detection's reading,
        // 31 December, stands.
        guard let result = calendar.date(from: parts),
              calendar.component(.month, from: result) == printed.month,
              calendar.component(.day, from: result) == printed.day else { return date }
        return result
    }

    /// The year a printed `year` stands for: itself when it has four digits.
    /// Two digits leave the century to data detection ("99" is 1999, "26" is
    /// 2026), so the year ending in them that is closest to `detected` is
    /// taken.
    private static func year(_ year: Int, closestTo detected: Int) -> Int {
        guard year < 100 else { return year }
        let century = detected - detected % 100
        return [century - 100, century, century + 100].map { $0 + year }
            .min { abs($0 - detected) < abs($1 - detected) }!
    }
}
