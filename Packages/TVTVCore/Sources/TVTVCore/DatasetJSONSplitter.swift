import Foundation

/// Streaming split of the single-object Dataset-JSON `.json` flavor into the
/// `.ndjson` line shape: line 1 is the metadata object (every top-level
/// attribute except `rows`), then one row array per line.
///
/// Why: DuckDB's JSON reader must hold a single object whole — for `.json`
/// that is the entire file, and the transcode peaked at ~70× the file size in
/// RAM. Splitting first is one pass over a memory-mapped file with O(row)
/// working memory, after which the `.ndjson` path (which streams) does the
/// rest. Row bytes are copied verbatim except for whitespace between tokens,
/// so numbers and strings reach DuckDB exactly as written.
extension DatasetJSON {

    enum SplitError: Error, CustomStringConvertible {
        case empty
        case invalidJSON(offset: Int, String)

        var description: String {
            switch self {
            case .empty: return "empty file"
            case .invalidJSON(let offset, let problem): return "not valid JSON: \(problem) at byte \(offset)"
            }
        }
    }

    /// Write `source` (a `.json` Dataset-JSON) to `destination` as `.ndjson`.
    /// `rows` normally comes last; when other attributes follow it, the
    /// already-streamed rows are re-prefixed with the complete metadata in a
    /// second, copy-only pass.
    static func splitToNDJSON(source: URL, destination: URL) throws {
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw SplitError.invalidJSON(offset: 0, "could not create \(destination.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: destination)
        var needsPrefixRewrite = false
        var provisionalHeaderLength = 0
        var metadataLine = [UInt8]()
        do {
            defer { try? handle.close() }
            var writer = LineWriter(handle: handle)
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var scanner = JSONSplitScanner(bytes: raw.bindMemory(to: UInt8.self))
                let result = try scanner.split(into: &writer)
                metadataLine = result.metadataLine
                needsPrefixRewrite = result.attributesFollowedRows
                provisionalHeaderLength = result.provisionalHeaderLength
            }
            try writer.flush()
        }
        if needsPrefixRewrite {
            try rewrite(destination, replacingFirst: provisionalHeaderLength, with: metadataLine)
        }
    }

    /// Replace the first `headerLength` bytes of `url` with `header` + "\n",
    /// streaming the remainder through a sibling temp file.
    private static func rewrite(_ url: URL, replacingFirst headerLength: Int, with header: [UInt8]) throws {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).rows-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        let input = try FileHandle(forReadingFrom: staged)
        defer { try? input.close() }
        try input.seek(toOffset: UInt64(headerLength))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.write(contentsOf: Data(header + [UInt8(ascii: "\n")]))
        while let chunk = try input.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }
}

/// Buffered line output; flushes in ~1MB batches.
private struct LineWriter {
    let handle: FileHandle
    private var buffer: [UInt8] = {
        var b = [UInt8](); b.reserveCapacity(1 << 20); return b
    }()
    private(set) var bytesWritten = 0

    init(handle: FileHandle) { self.handle = handle }

    mutating func writeLine(_ bytes: [UInt8]) throws {
        buffer.append(contentsOf: bytes)
        buffer.append(UInt8(ascii: "\n"))
        bytesWritten += bytes.count + 1
        if buffer.count >= 1 << 20 { try flush() }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Byte-level scanner over one top-level JSON object. Only the top level is
/// interpreted; every value is copied through with inter-token whitespace
/// removed (strings untouched, escapes passed through).
private struct JSONSplitScanner {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    struct Result {
        let metadataLine: [UInt8]
        /// True when a non-`rows` attribute appeared after `rows`, so the
        /// metadata line written before the rows is incomplete.
        let attributesFollowedRows: Bool
        /// Length (bytes, incl. newline) of that provisional metadata line.
        let provisionalHeaderLength: Int
    }

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    private var atEnd: Bool { index >= bytes.count }

    private func fail(_ problem: String) -> DatasetJSON.SplitError {
        .invalidJSON(offset: index, problem)
    }

    mutating func split(into writer: inout LineWriter) throws -> Result {
        skipWhitespace()
        guard !atEnd else { throw DatasetJSON.SplitError.empty }
        try expect(UInt8(ascii: "{"), "expected an object")
        var metadata: [UInt8] = [UInt8(ascii: "{")]
        var sawRows = false
        var attributesFollowedRows = false
        var provisionalHeaderLength = 0

        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            index += 1
        } else {
            while true {
                skipWhitespace()
                var key = [UInt8]()
                try copyString(into: &key)
                skipWhitespace()
                try expect(UInt8(ascii: ":"), "expected ':' after key")
                skipWhitespace()
                if key == Array(#""rows""#.utf8) {
                    guard !sawRows else { throw fail("duplicate \"rows\"") }
                    sawRows = true
                    // Provisional header: the metadata seen so far. Complete
                    // if (as is usual) nothing but '}' follows the rows.
                    var provisional = metadata
                    provisional.append(UInt8(ascii: "}"))
                    try writer.writeLine(provisional)
                    provisionalHeaderLength = provisional.count + 1
                    try streamRows(into: &writer)
                } else {
                    if sawRows { attributesFollowedRows = true }
                    if metadata.count > 1 { metadata.append(UInt8(ascii: ",")) }
                    metadata.append(contentsOf: key)
                    metadata.append(UInt8(ascii: ":"))
                    try copyValue(into: &metadata)
                }
                skipWhitespace()
                guard let b = peek else { throw fail("unterminated object") }
                index += 1
                if b == UInt8(ascii: "}") { break }
                guard b == UInt8(ascii: ",") else { throw fail("expected ',' or '}'") }
            }
        }
        skipWhitespace()
        guard atEnd else { throw fail("unexpected content after the object") }
        metadata.append(UInt8(ascii: "}"))
        if !sawRows {
            try writer.writeLine(metadata)  // metadata-only dataset
        }
        return Result(
            metadataLine: metadata, attributesFollowedRows: attributesFollowedRows,
            provisionalHeaderLength: provisionalHeaderLength)
    }

    /// `[` elem, elem, … `]` — one line per element.
    private mutating func streamRows(into writer: inout LineWriter) throws {
        try expect(UInt8(ascii: "["), "\"rows\" must be an array")
        skipWhitespace()
        if peek == UInt8(ascii: "]") { index += 1; return }
        var row = [UInt8]()
        while true {
            skipWhitespace()
            row.removeAll(keepingCapacity: true)
            try copyValue(into: &row)
            try writer.writeLine(row)
            skipWhitespace()
            guard let b = peek else { throw fail("unterminated rows array") }
            index += 1
            if b == UInt8(ascii: "]") { return }
            guard b == UInt8(ascii: ",") else { throw fail("expected ',' or ']' in rows") }
        }
    }

    // MARK: Primitives

    private var peek: UInt8? { atEnd ? nil : bytes[index] }

    /// Quote, bracket, or whitespace — the bytes the container copier must
    /// look at; everything else is copied through in runs.
    @inline(__always)
    private static func isStructural(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "\""), UInt8(ascii: "{"), UInt8(ascii: "["), UInt8(ascii: "}"), UInt8(ascii: "]"),
             0x20, 0x09, 0x0A, 0x0D:
            return true
        default:
            return false
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func expect(_ byte: UInt8, _ problem: String) throws {
        guard peek == byte else { throw fail(problem) }
        index += 1
    }

    /// Copy one string literal, quotes included, escapes passed through.
    private mutating func copyString(into out: inout [UInt8]) throws {
        guard peek == UInt8(ascii: "\"") else { throw fail("expected a string") }
        let start = index
        index += 1
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            index += 1
            if b == UInt8(ascii: "\"") {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<index]))
                return
            }
        }
        throw fail("unterminated string")
    }

    /// Copy one value (any type) with whitespace between tokens removed.
    private mutating func copyValue(into out: inout [UInt8]) throws {
        guard let first = peek else { throw fail("expected a value") }
        switch first {
        case UInt8(ascii: "\""):
            try copyString(into: &out)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            // Copy runs of plain bytes in one go; only strings, brackets and
            // whitespace need a look (per-byte appends were ~4× slower).
            var depth = 0
            while index < bytes.count {
                let runStart = index
                var b = bytes[index]
                while !Self.isStructural(b) {
                    index += 1
                    guard index < bytes.count else { throw fail("unterminated value") }
                    b = bytes[index]
                }
                if index > runStart {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<index]))
                }
                switch b {
                case UInt8(ascii: "\""):
                    try copyString(into: &out)
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                default:  // whitespace
                    index += 1
                    continue
                }
                out.append(b)
                index += 1
                if depth == 0 { return }
            }
            throw fail("unterminated value")
        default:
            // Scalar: number, true, false, null — up to the next delimiter.
            let start = index
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), 0x20, 0x09, 0x0A, 0x0D:
                    break
                default:
                    index += 1
                    continue
                }
                break
            }
            guard index > start else { throw fail("expected a value") }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<index]))
        }
    }
}
