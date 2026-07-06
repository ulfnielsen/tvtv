import CTvtvVortex
import Foundation

/// Swift wrapper over the `tvtv-vortex` Rust FFI (`CTvtvVortex`). DuckDB
/// cannot read Vortex natively, so:
///   - `loadPreview` materializes the first rows into a `FilePreview` (used by
///     QuickLook), and
///   - `convertToParquet` transcodes a whole Vortex file to a temporary
///     Parquet the main app then opens through DuckDB (full paging, real
///     types) — the same strategy the original TVTV used.
public enum VortexReader {

    public enum VortexError: LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// Materialize up to `rowCap` rows of the Vortex file at `url` for preview.
    public static func loadPreview(url: URL, rowCap: Int = 200) throws -> FilePreview {
        var handle: OpaquePointer?
        var errorPtr: UnsafeMutablePointer<CChar>?
        let status = url.path.withCString {
            tvtv_vortex_preview($0, Int64(rowCap), &handle, &errorPtr)
        }
        guard status == 0, let handle else {
            throw error(from: errorPtr, fallback: "Could not read Vortex file.")
        }
        defer { tvtv_vortex_preview_free(handle) }

        let columnCount = Int(tvtv_vortex_preview_column_count(handle))
        let rowCount = Int(tvtv_vortex_preview_row_count(handle))
        let totalRows = Int(tvtv_vortex_preview_total_rows(handle))
        let truncated = tvtv_vortex_preview_truncated(handle) != 0

        let columns: [FilePreview.Column] = (0..<columnCount).map { c in
            let name = tvtv_vortex_preview_column_name(handle, UInt64(c)).map { String(cString: $0) } ?? ""
            let type = tvtv_vortex_preview_column_type(handle, UInt64(c)).map { String(cString: $0) } ?? ""
            return FilePreview.Column(name: name, type: type)
        }

        var rows: [[String?]] = []
        rows.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            let row: [String?] = (0..<columnCount).map { c in
                tvtv_vortex_preview_cell(handle, UInt64(r), UInt64(c)).map { String(cString: $0) }
            }
            rows.append(row)
        }

        return FilePreview(columns: columns, rows: rows, totalRowCount: totalRows, truncated: truncated)
    }

    /// Convert the Vortex file at `src` to a fresh temporary Parquet file and
    /// return its URL. The caller owns the temp file (delete when done).
    public static func convertToParquet(_ src: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-vortex-\(UUID().uuidString).parquet")
        var errorPtr: UnsafeMutablePointer<CChar>?
        let status = src.path.withCString { s in
            dest.path.withCString { d in
                tvtv_vortex_to_parquet(s, d, &errorPtr)
            }
        }
        guard status == 0 else {
            throw error(from: errorPtr, fallback: "Could not convert Vortex file to Parquet.")
        }
        return dest
    }

    /// Build a `VortexError` from a caller-owned FFI error string, freeing it.
    private static func error(from ptr: UnsafeMutablePointer<CChar>?, fallback: String) -> VortexError {
        guard let ptr else { return .failed(fallback) }
        let message = String(cString: ptr)
        tvtv_vortex_string_free(ptr)
        return .failed(message.isEmpty ? fallback : message)
    }
}
