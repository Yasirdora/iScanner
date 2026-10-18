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
            for (date, same) in zip(reading.dates, other.dates) where date != nil && date == same {
                found.append(ISO8601DateFormatter().string(from: date!))
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
}
