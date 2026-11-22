import Foundation

/// Default and user-edited recording titles.
enum RecordingTitle {
    /// "Recording 14:03" (locale-aware clock), made unique against `existing`
    /// with a " (2)", " (3)"… suffix so two recordings in the same minute
    /// stay distinguishable in the list.
    static func makeDefault(startedAt: Date, existing: [String] = [],
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        let base = "Recording \(startedAt.formatted(style))"
        let taken = Set(existing)
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) (\(counter))") { counter += 1 }
        return "\(base) (\(counter))"
    }

    /// Trims whitespace/newlines and collapses inner runs of whitespace.
    /// Returns nil for an empty result (the caller keeps the old title).
    static func normalized(_ proposed: String) -> String? {
        let collapsed = proposed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(120))
    }
}
