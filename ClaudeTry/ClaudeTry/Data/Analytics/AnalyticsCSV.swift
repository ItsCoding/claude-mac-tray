import Foundation

/// CSV builders for the analytics export (buckets of the current view, filtered sessions).
/// All timestamps are local time with an explicit UTC offset.
enum AnalyticsCSV {
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Quote a free-text cell and neutralise spreadsheet formula injection
    /// (cells starting with = + - @ tab or CR get a leading single quote).
    static func text(_ s: String) -> String {
        if let c = s.first, "=+-@\t\r".contains(c) { return quote("'" + s) }
        return quote(s)
    }

    private static func formatter(_ calendar: Calendar) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = calendar.timeZone
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    static func buckets(_ r: AnalyticsResult, calendar: Calendar = .current) -> String {
        let iso = formatter(calendar)
        var lines = [(["bucket_start"] + r.series.map(\.key) + ["total"]).map(text).joined(separator: ",")]
        let totals = r.totalValues
        let cols = r.series.map { r.values(of: $0) }
        for i in r.starts.indices {
            let cells = [iso.string(from: r.starts[i])] + cols.map { String(format: "%.4f", $0[i]) } + [String(format: "%.4f", totals[i])]
            lines.append(cells.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func sessions(_ rows: [SessionRow], calendar: Calendar = .current) -> String {
        let iso = formatter(calendar)
        var lines = ["started,session,project,model,type,profile,messages,tool_calls,tokens,cost_usd,lines_added,lines_removed,cache_hit,duration_s"]
        for s in rows {
            let textual = [s.id, s.project, s.model].map(text)
            let cells: [String] = [quote(iso.string(from: s.start))] + textual + [
                s.isSubagent ? "subagent" : "main", s.profile.rawValue,
                String(s.messages), String(s.toolCalls), String(s.tokens),
                String(format: "%.4f", s.cost), String(s.linesAdded), String(s.linesRemoved),
                String(format: "%.4f", s.cacheHit), String(Int(s.durationSec))
            ].map(quote)
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
