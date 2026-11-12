import Foundation

/// Formats grid rows as tab-separated text for the pasteboard — the format
/// Excel, Numbers, Google Sheets and most text editors accept on paste.
///
/// NULL is written as an empty field. A field containing a tab, newline,
/// carriage return or double quote is wrapped in double quotes with inner
/// quotes doubled (the convention spreadsheets use for TSV paste), so a
/// multi-line cell stays one cell.
public enum RowClipboard {

    /// Upper bound on rows copied in one go: a ⌘A on a 60M-row file would
    /// otherwise build gigabytes of text on the main thread.
    public static let maxRows = 100_000

    public static func tsv(header: [String]?, rows: [[Cell]]) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        if let header {
            lines.append(header.map(field).joined(separator: "\t"))
        }
        for row in rows {
            lines.append(row.map { cell in
                switch cell {
                case .null: return ""
                case .text(let s): return field(s)
                }
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
