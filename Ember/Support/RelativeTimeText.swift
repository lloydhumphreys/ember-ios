import SwiftUI

/// A timestamp in `RelativeTime`'s short form ("Now", "5m", "2h", "Yesterday", then a date),
/// moving on by itself: a plain `Text` only recomputes when something else redraws it, so a row
/// saying "5m" would say it for ever.
struct RelativeTimeText: View {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(RelativeTime.short(date, relativeTo: context.date))
                .accessibilityLabel(RelativeTime.long(date, relativeTo: context.date))
        }
    }
}

/// Relative times as Mail and Messages write them. Every function clamps `date` to `now` first,
/// so a server clock running a little ahead never reads "in 0 seconds". Pure: `now` and
/// `calendar` are parameters.
enum RelativeTime {
    /// "Now", "5m", "2h", "Yesterday", then a short date.
    static func short(
        _ date: Date, relativeTo now: Date = .now,
        calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent
    ) -> String {
        let clamped = min(date, now)
        let elapsed = now.timeIntervalSince(clamped)
        if elapsed < 60 { return "Now" }
        if calendar.isDate(clamped, inSameDayAs: now) {
            if elapsed < 3600 { return "\(Int(elapsed / 60))m" }
            return "\(Int(elapsed / 3600))h"
        }
        // Measured against `now` rather than `Calendar.isDateInYesterday`, which uses the real
        // clock's today.
        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           calendar.startOfDay(for: clamped) == yesterday {
            return "Yesterday"
        }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let sameYear = calendar.component(.year, from: clamped) == calendar.component(.year, from: now)
        return sameYear
            ? clamped.formatted(style.month(.abbreviated).day())
            : clamped.formatted(style.month(.abbreviated).day().year())
    }

    /// "just now", "yesterday", "3 days ago": for VoiceOver.
    static func long(_ date: Date, relativeTo now: Date = .now, locale: Locale = .autoupdatingCurrent) -> String {
        let clamped = min(date, now)
        if now.timeIntervalSince(clamped) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: clamped, relativeTo: now)
    }
}
