import Foundation
import XCTest
@testable import TVTVCore

/// The single-object `.json` flavor is split, streaming, into the `.ndjson`
/// shape (metadata line, then one row array per line) so DuckDB never has to
/// hold the whole file as one object.
final class DatasetJSONSplitterTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvtv-splitter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func split(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let source = tempDirectory.appendingPathComponent("in-\(UUID().uuidString).json")
        let destination = tempDirectory.appendingPathComponent("out-\(UUID().uuidString).ndjson")
        try json.write(to: source, atomically: true, encoding: .utf8)
        try DatasetJSON.splitToNDJSON(source: source, destination: destination)
        let output = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(output.hasSuffix("\n"), "every line, including the last, ends with a newline", file: file, line: line)
        return output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    func testMetadataLineThenOneLinePerRow() throws {
        let lines = try split(#"{"datasetJSONVersion":"1.1.0","records":2,"columns":[{"name":"A"}],"rows":[[1,"x"],[2,"y"]]}"#)
        XCTAssertEqual(lines, [
            #"{"datasetJSONVersion":"1.1.0","records":2,"columns":[{"name":"A"}]}"#,
            #"[1,"x"]"#,
            #"[2,"y"]"#,
        ])
    }

    func testRowsBeforeMetadataStillPutsCompleteMetadataOnLineOne() throws {
        let lines = try split(#"{"rows":[[1],[2]],"datasetJSONVersion":"1.1.0","name":"DM"}"#)
        XCTAssertEqual(lines, [#"{"datasetJSONVersion":"1.1.0","name":"DM"}"#, "[1]", "[2]"])
    }

    func testRowsBetweenAttributesMergesBothSidesIntoMetadata() throws {
        let lines = try split(#"{"a":1,"rows":[[1]],"b":2}"#)
        XCTAssertEqual(lines, [#"{"a":1,"b":2}"#, "[1]"])
    }

    func testPrettyPrintedInputCompactsTokensButKeepsStringsVerbatim() throws {
        let lines = try split("""
            {
              "name" : "D M",
              "columns" : [ { "name" : "A" } ],
              "rows" : [
                [ 1, "a  b\\tc" ],
                [ 2, null ]
              ]
            }
            """)
        XCTAssertEqual(lines, [#"{"name":"D M","columns":[{"name":"A"}]}"#, #"[1,"a  b\tc"]"#, "[2,null]"])
    }

    func testEscapedQuotesAndBracketsInsideStringsDoNotConfuseTheScanner() throws {
        let lines = try split(#"{"rows":[["say \"hi\" ]}", "x\\", "{[,]}"]],"label":"a \"rows\" b"}"#)
        XCTAssertEqual(lines, [#"{"label":"a \"rows\" b"}"#, #"["say \"hi\" ]}","x\\","{[,]}"]"#])
    }

    func testNestedObjectsInMetadataAndRowsCopyThrough() throws {
        let lines = try split(#"{"sourceSystem":{"name":"S","version":"1"},"rows":[[{"rows":[1,2]},[3,[4]]]]}"#)
        XCTAssertEqual(lines, [#"{"sourceSystem":{"name":"S","version":"1"}}"#, #"[{"rows":[1,2]},[3,[4]]]"#])
    }

    func testNumbersAndUnicodePassThroughVerbatim() throws {
        let lines = try split(#"{"rows":[[-1.50e+3,0.10,true,false,null,"Ærø 日本 é"]]}"#)
        XCTAssertEqual(lines, ["{}", #"[-1.50e+3,0.10,true,false,null,"Ærø 日本 é"]"#])
    }

    func testEmptyRowsArrayYieldsOnlyTheMetadataLine() throws {
        XCTAssertEqual(try split(#"{"name":"DM","rows":[ ]}"#), [#"{"name":"DM"}"#])
    }

    func testMissingRowsKeyYieldsOnlyTheMetadataLine() throws {
        XCTAssertEqual(try split(#"{"name":"DM","records":0}"#), [#"{"name":"DM","records":0}"#])
    }

    func testEmptyFileThrowsEmpty() throws {
        XCTAssertThrowsError(try split("  \n")) { error in
            guard case DatasetJSON.SplitError.empty = error else { return XCTFail("got \(error)") }
        }
    }

    func testInvalidInputsThrowInvalidJSON() throws {
        for bad in ["this is not json at all", "[1,2,3]", #"{"rows":[[1],[2]}"#, #"{"rows":[[1]]} trailing"#,
                    #"{"a":1 "b":2}"#, #"{"rows":[[1]],"rows":[[2]]}"#, #"{"rows":{"x":1}}"#, #"{"a":"unterminated}"#] {
            XCTAssertThrowsError(try split(bad), "should reject: \(bad)") { error in
                guard case DatasetJSON.SplitError.invalidJSON = error else { return XCTFail("got \(error) for \(bad)") }
            }
        }
    }

    func testLargeRowsFlushAcrossWriterBufferBoundary() throws {
        // > 1MB of rows so the writer flushes mid-stream; also exercises the
        // rewrite path with a big body.
        let row = "[" + (0..<50).map { "\"cell \($0) padding padding\"" }.joined(separator: ",") + "]"
        let rows = (0..<1500).map { _ in row }.joined(separator: ",")
        let lines = try split(#"{"rows":["# + rows + #"],"name":"BIG"}"#)
        XCTAssertEqual(lines.count, 1501)
        XCTAssertEqual(lines[0], #"{"name":"BIG"}"#)
        XCTAssertEqual(lines[1], row)
        XCTAssertEqual(lines[1500], row)
    }
}
