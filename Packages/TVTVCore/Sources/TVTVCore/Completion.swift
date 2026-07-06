import Foundation

/// SQL keywords the editor's autocomplete offers, in the fixed order they
/// are checked (does not affect result ordering — see `sqlCompletions`).
/// Deliberately a flat literal list (no grammar/parser) — this is
/// prefix-suggestion only, not a SQL-aware editor.
public enum SQLKeyword {
    public static let all: [String] = [
        "SELECT", "FROM", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT", "OFFSET",
        "JOIN", "ON", "AS", "DISTINCT", "COUNT", "SUM", "AVG", "MIN", "MAX",
        "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "ASC", "DESC",
    ]
}

/// The SQL editor's pure autocomplete provider: given the identifier
/// fragment currently being typed and the lightweight context of what's
/// available right now (the view/table names the grid can switch to, and
/// the open file's column names), returns an ordered list of suggestions
/// drawn from three sources — columns, tables, and `SQLKeyword.all`.
///
/// ## Filtering: prefix match, case-insensitive
///
/// A candidate is included when it **starts with** `prefix`,
/// case-insensitively (`candidate.lowercased().hasPrefix(prefix.lowercased())`).
/// Substring matching was considered but prefix match is what a SQL
/// editor's caret-completion actually wants: typing "ord" should offer
/// "ORDER BY", not every keyword that happens to contain "ord" somewhere in
/// the middle — and it is the simpler, more predictable of the two (YAGNI:
/// no fuzzy ranking).
///
/// ## Empty prefix → empty result
///
/// Documented choice: nothing typed yet suggests nothing, rather than
/// dumping the full keyword/table/column list into the popup on every
/// keystroke of leading whitespace. The caller (the editor) only invokes
/// this once a non-empty identifier fragment is under/before the caret.
///
/// ## Ordering
///
/// 1. An **exact** case-insensitive match to `prefix` sorts before any
///    longer prefix match, regardless of category — the user typing the
///    whole word wants that word first.
/// 2. Ties are broken by category precedence: **columns, then tables,
///    then keywords** — the column you are about to reference is the most
///    likely thing you're typing (SQL editors spend far more characters on
///    column names than on the small closed keyword set).
/// 3. Within a tied category, alphabetical (`localizedStandardCompare`) for
///    a deterministic result.
///
/// Duplicate **exact strings** across categories (e.g. a column named
/// literally "data" and a table named "data") are suggested once. A
/// same-spelling-different-case pair (a column "as" vs. the keyword "AS")
/// is NOT collapsed — the two are different literal insertions (the
/// column's own casing vs. the keyword's canonical casing), so both are
/// kept; dedup is by exact string equality, not case-folded identity.
public func sqlCompletions(prefix: String, tables: [String], columns: [String]) -> [String] {
    guard !prefix.isEmpty else { return [] }
    let lowerPrefix = prefix.lowercased()

    // Category precedence for tie-breaking: columns, then tables, then
    // keywords (see the doc's "Ordering" section).
    let candidates: [(value: String, category: Int)] =
        columns.map { ($0, 0) } + tables.map { ($0, 1) } + SQLKeyword.all.map { ($0, 2) }

    func rank(_ candidate: String) -> Int {
        candidate.lowercased() == lowerPrefix ? 0 : 1
    }

    let sorted = candidates
        .filter { $0.value.lowercased().hasPrefix(lowerPrefix) }
        .sorted { a, b in
            let (ra, rb) = (rank(a.value), rank(b.value))
            if ra != rb { return ra < rb }
            if a.category != b.category { return a.category < b.category }
            return a.value.localizedStandardCompare(b.value) == .orderedAscending
        }

    var seen = Set<String>()
    var result: [String] = []
    for candidate in sorted where seen.insert(candidate.value).inserted {
        result.append(candidate.value)
    }
    return result
}
