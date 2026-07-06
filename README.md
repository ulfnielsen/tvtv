# TVTV

TVTV is a fast macOS viewer for **parquet, csv, vortex, and duckdb** files. It
opens very large tables (100M+ rows) quickly and stays responsive by paging
data on demand rather than loading whole files into memory.

## Features

- **Grid** — virtualized `NSTableView` rendering; opens multi-GB files fast and
  pages rows lazily (10,000-row pages) so memory stays flat with file size.
- **Sort / filter / search** — click a header to sort, per-column quick-filter
  popovers, and in-grid text search with next/previous (⌘G / ⇧⌘G) and highlight.
- **SQL editor** — run DuckDB SQL over the open file (⌘-Return), with keyword/
  table/column autocomplete. The current file is queryable as `data` or by its
  file name.
- **Cell editing** — double-click to edit; save back to the file (⌘S) or Save
  As (⇧⌘S); undo with ⌘Z.
- **Toolbar** — open, attach another file as a table, reload, export to CSV.
- **Minimap** — scroll-position overview; click or drag it to jump.
- **QuickLook** — Finder previews for parquet / csv / duckdb / vortex.

## Architecture

TVTV is a SwiftUI/AppKit app with an embedded Rust static library:

- **TVTVApp** (Swift) — app layer: `AppModel`, `DataSource`, `SQLEditor`, the
  SwiftUI `ContentView`.
- **TVTVCore** (Swift) — the grid engine: `GridTableView`,
  `GridTableHeaderView`, `DataGridCoordinator`, `RowContentView`,
  `RowStore`, `MinimapOverlayView`, `FilePreview`, `VortexReader`.
- **tvtv-vortex** (Rust staticlib) — Vortex format support via a C FFI surface
  (DuckDB can't read Vortex directly, so `.vtx` files are transcoded to a
  temporary parquet for paging).
- **DuckDB** (duckdb-swift) — the query/paging engine for parquet/csv/duckdb.

## Building

```bash
scripts/build.sh            # optimized Release build -> dist/TVTV.app
scripts/build.sh --debug    # faster debug build for the dev loop
scripts/build.sh --run      # build, then launch
```

The Rust staticlib is built automatically as a pre-compile step. Version is
stamped via `scripts/version.sh <major.minor.patch>`.

## Benchmarking

`scripts/gen-benchmark-data.py` generates fixtures for performance testing. It
prefers the `duckdb` CLI (streams row generation even at 100M+ rows) and falls
back to pyarrow.

```bash
python3 scripts/gen-benchmark-data.py --smoke   # tiny fixtures for CI / fast local testing
python3 scripts/gen-benchmark-data.py           # full-scale fixtures (100M+ rows, multi-GB) — slow
```

Fixtures land in `data/bench/` (git-ignored):

| Fixture | Full scale | Smoke scale | Purpose |
|---|---|---|---|
| `wide_100m.parquet` / `smoke_wide.parquet` | 100,000,000 rows x 30 cols | 5,000 rows | mixed int/float/bool/string/date/timestamp — the realistic "big wide table" case |
| `longstrings.parquet` / `smoke_longstrings.parquet` | 5,000,000 rows x 5 cols | 2,000 rows | long varchar cells (~1.3KB+), worst case for text layout/measurement |
| `big.csv` / `smoke_big.csv` | 25,000,000 rows x 15 cols | 3,000 rows | multi-GB plain CSV, worst case for streaming/parse cost |

`scripts/bench.sh <app-bundle> <file>` launches an app bundle on a file,
measures cold-open wall time and peak RSS, and prints a one-line result:

```bash
scripts/bench.sh dist/TVTV.app data/bench/smoke_wide.parquet
```
