# Column Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the column labels already embedded in CDISC Dataset-JSON and Derive Parquet files.

**Architecture:** Read the embedded Arrow schema in the existing Rust Parquet library and pass only name/label pairs over the existing C bridge. The app puts the optional label on `ColumnInfo`; the shared grid renders it separately from the physical name and type.

**Tech Stack:** Rust `parquet`/`arrow` 57.3.0, C FFI, Swift, AppKit, DuckDB, XCTest.

**Spec:** [Column labels design](../specs/2026-11-18-column-labels-design.md); Derive wire contract at `/Users/ulfnielsen/dev/concordat/derive/docs/authoring/parquet-column-labels.md`.

## Global Constraints

- Read embedded `ARROW:schema`; exact lowercase field metadata key `label`; top-level fields only. No sidecar; no row scan or new dependencies.
- Identity, existing displayed types, query behavior, and exported column names do not change. Optional or unreadable metadata never blocks opening a readable file.
- Keep the current one-line layout when no labels exist; otherwise put labels in a muted second line with full hover text. Preserve the existing macOS 14 deployment target.
- Keep the pre-existing row-navigation working-tree changes out of feature commits. In particular, stage hunks separately if adding labels directly to `DataGridCoordinator.swift`.

## Review Focus

- Unicode and repeated labels are text, not identity (Tasks 1–2).
- A file without rows can still carry labels (Task 1).
- Wrong-case, nested, missing and malformed Arrow metadata must not leak as labels (Tasks 1–2).
- Reordering columns must move their labels and hover text with them, not leave labels at old indices (Task 3).
- Switching back to an unlabelled dataset restores the one-line header (Task 3).

---

### Task 1: Read Parquet footer labels through the Rust bridge

**Files:** Modify `rust/tvtv-vortex/src/lib.rs`, `Packages/TVTVCore/Sources/CTvtvVortex/include/tvtv_vortex.h`, `scripts/build-rust.sh`; create `Packages/TVTVCore/Sources/TVTVCore/ParquetColumnLabels.swift`.

**Produces:** `read_parquet_column_labels(path: &str) -> Result<Vec<(String, String)>, String>` in Rust; `tvtv_parquet_read_column_labels(path, context, callback)` in C; `public enum ParquetColumnLabels { public static func read(from url: URL) -> [String: String] }` in Swift.

- [ ] In a Rust test, use `ArrowWriter` with zero rows and explicit field metadata. Assert `read_parquet_column_labels(path).unwrap()` matches `[("AGE", "Âge à la visite"), ("XAGE", "Âge à la visite")]` in file order. Include `SEX` with `Label` instead of `label`, an empty lowercase label, and a nested field whose label must not surface. Add a second fixture with `with_skip_arrow_metadata(true)` and expect an empty vector.
- [ ] Run `cargo test --manifest-path rust/tvtv-vortex/Cargo.toml parquet_column_labels`; verify the reader is missing before implementing it.
- [ ] Implement with `ParquetRecordBatchReaderBuilder::try_new(File::open(path)?)`; take `.schema().fields()` without building or reading a batch. Export the Rust reader through a synchronous C callback receiving context and two borrowed UTF-8 pointer/length pairs, valid only during the callback. Return nonzero for unreadable metadata, and do not invoke the callback on failure. Update the checked-in C declaration and verify the added export by name in `scripts/build-rust.sh`. Swift decodes into a local dictionary; failure yields `[:]`.
- [ ] Run the targeted Cargo tests and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-rust.sh`; expect passing tests and the new symbol in the static library.
- [ ] Commit only the Rust reader and bridge files.

### Task 2: Resolve file labels onto the grid schema

**Files:** Modify `TVTVApp/DataSource.swift`, `Packages/TVTVCore/Sources/TVTVCore/DataGridCoordinator.swift` (`ColumnInfo` only), `TVTVAppTests/DataSourceTests.swift` and `TVTVAppTests/DatasetJSONTests.swift`; add the 1.7 KB Derive example under `data/fixtures/` with provenance noted in the test.

**Consumes:** `ParquetColumnLabels.read(from:)`. **Produces:** `ColumnInfo.label: String?` and trailing initializer argument `label: String? = nil`.

- [ ] Add app tests asserting that opening the Derive fixture yields names `["USUBJID", "AGE", "SEX", "XAGE"]` with labels `["Unique Subject Identifier", "Age", nil, "Âge à la visite"]`; assert that an existing plain Parquet fixture still opens with no labels. Add a fixture with a malformed `ARROW:schema` footer value and assert the underlying Parquet still opens with no labels. In the existing Dataset-JSON open fixture, assert `USUBJID` and `AGE` map to `"Unique Subject Identifier"` and `"Age"`, respectively, for both JSON and NDJSON.
- [ ] Run the relevant app tests with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project TVTV.xcodeproj -scheme TVTVApp -configuration Debug -destination 'platform=macOS' -derivedDataPath build/xcode` and `-only-testing` for the new tests; verify missing labels before implementing.
- [ ] Populate labels in `DataSource.open`: use the original Parquet file URL, or native Dataset-JSON metadata for both JSON flavors. Join by exact name, treat empty labels as absent, and preserve DuckDB's name, SQL type and source index. Do not inspect temporary transcoded Parquet, or infer labels for SQL results.
- [ ] Rerun the targeted app tests; expect the labeled and fallback cases to pass.
- [ ] Commit the ingestion changes without unrelated row-navigation hunks.

### Task 3: Render label subtitles and hover text

**Files:** Modify `Packages/TVTVCore/Sources/TVTVCore/{DataGridCoordinator,GridTableHeaderView,DataGrid}.swift`, `Packages/TVTVCore/Tests/TVTVCoreTests/GridTableHeaderViewTests.swift`, and `README.md`.

**Consumes:** `ColumnInfo.label`. **Produces:** `GridTableHeaderView.columnLabel(atDisplayIndex: Int) -> String?` and `GridTableHeaderView.preferredHeight: CGFloat` for layout (28 pt without labels, 38 pt with labels).

- [ ] Write header tests asserting that a label for source column 0 follows it to display index 1 after reordering, unlabeled columns return nil, and swapping to an unlabeled header shrinks a hosted `GridContainerView` grid offset from 38 to 28 pt. Run `swift test --package-path Packages/TVTVCore --filter GridTableHeaderViewTests`; verify missing behavior before implementing.
- [ ] Pass optional source-indexed metadata into the header and map it through `ColumnLayout` during draw and tooltip hit-testing. Draw the name and type on line one and truncate the muted label on line two. Keep tooltip geometry in sync with resize, reordering and horizontal scroll. Use the header's preferred height in the container and preserve the existing controls. Document hover labels and off-by-default behavior for files without metadata in the README.
- [ ] Run the Rust, core Swift and macOS app suites. Smoke-check a labeled Derive example, an unlabeled file, and a narrow scrolled column in the app; verify full hover text and physical identifiers in SQL. Note any skipped suites explicitly.
- [ ] Commit only the remaining label-display changes.
