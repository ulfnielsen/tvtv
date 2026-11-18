import CTvtvVortex
import Foundation

/// Optional labels from the embedded Arrow schema in a Parquet footer.
public enum ParquetColumnLabels {
    public static func read(from url: URL) -> [String: String] {
        var labels: [String: String] = [:]
        let status = withUnsafeMutablePointer(to: &labels) { context in
            url.path.withCString { path in
                tvtv_parquet_read_column_labels(path, context) { context, name, nameLength, label, labelLength in
                    guard let context, let name, let label else { return }
                    let key = String(decoding: UnsafeBufferPointer(start: name, count: nameLength), as: UTF8.self)
                    let value = String(decoding: UnsafeBufferPointer(start: label, count: labelLength), as: UTF8.self)
                    context.assumingMemoryBound(to: [String: String].self).pointee[key] = value
                }
            }
        }
        return status == 0 ? labels : [:]
    }
}
