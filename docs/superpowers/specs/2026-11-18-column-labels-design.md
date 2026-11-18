# Display column labels

Show the human-readable descriptions supplied by dataset authors without renaming their fields. Use the Derive Parquet column-label contract (`derive/docs/authoring/parquet-column-labels.md` in the Concordat checkout): the file footer's `ARROW:schema` holds Arrow IPC; only top-level fields' UTF-8 metadata values with the exact key `label` supply labels. Dataset-JSON and NDJSON already expose their declared `columns[].label`. Column labels are optional and need not be unique.

## Approaches

- **Read embedded metadata with the existing Rust Arrow/Parquet library (chosen).** It already understands the IPC framing, and schema access does not iterate rows. DuckDB still handles all data and types shown today.
- **Fetch the raw footer entry through DuckDB and decode it separately.** Possible, but requires a second Arrow IPC decoder in Swift or a Rust bridge anyway.
- **Adjacent JSON or an application-defined footer key.** Neither is part of the selected Derive contract. No sidecar is needed or used.

## Viewer behavior

Match metadata to physical column names, never labels or ordinals. Keep existing names and SQL types in the first header line and put each available label on a muted second line. Show the full text on hover when the second line is truncated. A table with no labels keeps the existing header height. Unknown, absent or unreadable metadata does not prevent opening or paging an otherwise readable file. Empty datasets still show their schema labels.

This is display-only: no changes to SQL, sort/filter, exported column names, search, or Quick Look. Writing or carrying Parquet metadata through Save or Save As is outside this change; Dataset-JSON's existing metadata round trip stays intact.
