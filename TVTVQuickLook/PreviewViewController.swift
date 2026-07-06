import Cocoa
import Quartz
import TVTVCore
import WebKit

/// QuickLook preview for the file types TVTV opens (parquet, csv/tsv,
/// duckdb, and — via the Rust reader — vortex). Renders the first rows as a
/// styled, theme-aware HTML table in a `WKWebView`, reusing `TVTVCore`'s
/// `FilePreview` (DuckDB) and `VortexReader` (FFI) so the formatting matches
/// the main app's grid.
final class PreviewViewController: NSViewController, QLPreviewingController {

    /// Rows to materialize for the preview — enough to be useful, capped so a
    /// huge file never stalls or blows the extension's memory budget.
    private static let rowCap = 200

    private lazy var webView = WKWebView()

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        self.view = webView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let html: String
            do {
                let preview = try Self.loadPreview(at: url, rowCap: Self.rowCap)
                html = Self.renderHTML(fileName: url.lastPathComponent, preview: preview)
            } catch {
                html = Self.renderError(
                    fileName: url.lastPathComponent,
                    message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            DispatchQueue.main.async {
                self.webView.loadHTMLString(html, baseURL: nil)
                handler(nil)
            }
        }
    }

    /// Route by extension: Vortex goes through the Rust FFI reader, everything
    /// else through DuckDB.
    private static func loadPreview(at url: URL, rowCap: Int) throws -> FilePreview {
        switch url.pathExtension.lowercased() {
        case "vtx", "vortex":
            return try VortexReader.loadPreview(url: url, rowCap: rowCap)
        default:
            return try FilePreview.load(url: url, rowCap: rowCap)
        }
    }

    // MARK: - Rendering

    private static func renderHTML(fileName: String, preview: FilePreview) -> String {
        let header = preview.columns.map { col in
            "<th><div class='n'>\(escape(col.name))</div><div class='t'>\(escape(col.type))</div></th>"
        }.joined()

        let body = preview.rows.map { row in
            let cells = row.map { value -> String in
                if let value { return "<td>\(escape(value))</td>" }
                return "<td class='null'></td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()

        let footer: String
        if preview.truncated {
            footer = "Showing \(preview.rows.count) of \(preview.totalRowCount) rows · \(preview.columns.count) columns"
        } else {
            footer = "\(preview.totalRowCount) rows · \(preview.columns.count) columns"
        }

        return page(title: fileName, content: """
        <table>
          <thead><tr>\(header)</tr></thead>
          <tbody>\(body)</tbody>
        </table>
        <div class="footer">\(escape(footer))</div>
        """)
    }

    private static func renderError(fileName: String, message: String) -> String {
        page(title: fileName, content: "<div class='error'>\(escape(message))</div>")
    }

    private static func page(title: String, content: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: 13px -apple-system, system-ui, sans-serif;
            margin: 0; padding: 0;
            color: canvastext; background: canvas;
          }
          .title {
            font-weight: 600; padding: 10px 14px;
            border-bottom: 1px solid color-mix(in srgb, canvastext 14%, transparent);
            position: sticky; top: 0; background: canvas;
          }
          .wrap { overflow: auto; }
          table { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
          th, td {
            text-align: left; padding: 4px 10px; white-space: nowrap;
            border-bottom: 1px solid color-mix(in srgb, canvastext 8%, transparent);
          }
          th {
            position: sticky; top: 0;
            background: color-mix(in srgb, canvastext 6%, canvas);
            vertical-align: bottom;
          }
          th .n { font-weight: 600; }
          th .t { font-weight: 400; font-size: 11px; opacity: 0.55; }
          td {
            font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 12px;
          }
          tbody tr:nth-child(even) { background: color-mix(in srgb, canvastext 3.5%, transparent); }
          .footer {
            padding: 8px 14px; font-size: 11px; opacity: 0.6;
            border-top: 1px solid color-mix(in srgb, canvastext 10%, transparent);
          }
          .error { padding: 20px; color: #d0393e; }
        </style></head>
        <body>
          <div class="title">\(escape(title))</div>
          <div class="wrap">\(content)</div>
        </body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
