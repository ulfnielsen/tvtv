import XCTest
@testable import TVTVCore

/// Tests for `sqlCompletions` — the SQL editor's pure autocomplete provider:
/// given the typed prefix and the current table/view names + the open file's
/// column names, return an ordered list of suggestions drawn from columns,
/// tables, and a fixed SQL keyword list — filtered case-insensitively by
/// PREFIX match (not substring; see the function's doc for why).
///
/// Ordering contract this suite locks in: within the combined result, an
/// exact (case-insensitive) match sorts before a longer prefix match;
/// candidates are otherwise grouped columns-then-tables-then-keywords, since
/// the column you're about to type is the most likely thing you want.
final class CompletionTests: XCTestCase {

    private let tables = ["data", "query_result", "customers"]
    private let columns = ["name", "email", "signup_date"]

    // MARK: - Column-position prefix

    func test_columnPrefix_returnsMatchingColumnName() {
        let result = sqlCompletions(prefix: "nam", tables: tables, columns: columns)
        XCTAssertEqual(result, ["name"])
    }

    func test_columnPrefix_isCaseInsensitive() {
        let result = sqlCompletions(prefix: "EMA", tables: tables, columns: columns)
        XCTAssertEqual(result, ["email"])
    }

    // MARK: - Table-position prefix

    func test_tablePrefix_returnsMatchingTableName() {
        let result = sqlCompletions(prefix: "cust", tables: tables, columns: columns)
        XCTAssertEqual(result, ["customers"])
    }

    func test_tablePrefix_query_result_matchesFullName() {
        let result = sqlCompletions(prefix: "query", tables: tables, columns: columns)
        XCTAssertEqual(result, ["query_result"])
    }

    // MARK: - Keyword-position prefix

    func test_keywordPrefix_sel_returnsSELECT() {
        let result = sqlCompletions(prefix: "sel", tables: tables, columns: columns)
        XCTAssertEqual(result, ["SELECT"])
    }

    func test_keywordPrefix_isCaseInsensitiveOnBothSides() {
        // Typed lowercase, keyword table stored uppercase.
        let result = sqlCompletions(prefix: "whe", tables: tables, columns: columns)
        XCTAssertEqual(result, ["WHERE"])
    }

    func test_keywordPrefix_ord_returnsOrderBy() {
        let result = sqlCompletions(prefix: "ord", tables: tables, columns: columns)
        XCTAssertEqual(result, ["ORDER BY"])
    }

    // MARK: - Mixed matches + ordering (exact match first, then grouping)

    func test_mixedPrefix_ordersColumnsBeforeTablesBeforeKeywords() {
        // "d" matches column "signup_date"? no—must share literal prefix.
        // Use a synthetic set where prefix "da" matches a column ("data_col"),
        // a table ("data"), and nothing else, to check group ordering when an
        // exact table match ties with a longer column match.
        let result = sqlCompletions(prefix: "da", tables: ["data"], columns: ["data_col"])
        // Neither is an exact match to "da", so ordering falls back to
        // group precedence: columns before tables before keywords.
        XCTAssertEqual(result, ["data_col", "data"])
    }

    func test_exactMatch_sortsBeforeLongerPrefixMatch_evenAcrossGroups() {
        // "data" is an EXACT match against the table "data", while
        // "data_col" is only a prefix match against the column — exact match
        // wins regardless of group.
        let result = sqlCompletions(prefix: "data", tables: ["data"], columns: ["data_col"])
        XCTAssertEqual(result, ["data", "data_col"])
    }

    // MARK: - No match / empty prefix

    func test_noMatch_returnsEmpty() {
        let result = sqlCompletions(prefix: "zzz", tables: tables, columns: columns)
        XCTAssertEqual(result, [])
    }

    func test_emptyPrefix_returnsEmpty() {
        // Documented choice: an empty prefix (nothing typed yet) suggests
        // nothing, rather than dumping every keyword/table/column — avoids a
        // giant popup on every keystroke of whitespace.
        let result = sqlCompletions(prefix: "", tables: tables, columns: columns)
        XCTAssertEqual(result, [])
    }

    // MARK: - Same-spelling-different-case across categories

    func test_columnAndKeywordSameSpellingDifferentCase_bothAppearDistinctly() {
        // "AS" and "ASC" are both keywords starting with "as"; a column
        // literally named "as" is a DIFFERENT string from either (exact-
        // string dedup, not case-folded), so all three are useful, distinct
        // suggestions. "as" and "AS" are both EXACT matches to the prefix
        // (rank 0), so group precedence (columns before keywords) puts the
        // column first; "ASC" is only a longer prefix match (rank 1) and
        // sorts last.
        let result = sqlCompletions(prefix: "as", tables: [], columns: ["as"])
        XCTAssertEqual(result, ["as", "AS", "ASC"])
    }

    func test_exactStringDuplicate_isNotRepeated() {
        // The SAME string appearing in both tables and columns (e.g. a
        // column literally named "data" alongside the "data" table) should
        // only be suggested once.
        let result = sqlCompletions(prefix: "data", tables: ["data"], columns: ["data"])
        XCTAssertEqual(result, ["data"])
    }
}
