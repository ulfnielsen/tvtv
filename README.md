# TVTV

TVTV is a fast macOS viewer for **parquet, csv, vortex, duckdb, and CDISC
Dataset-JSON** files. It
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
- **Cell editing** — double-click to edit; save back to the file (⌘S); undo
  with ⌘Z.
- **Save As** (⇧⌘S) — save an opened file, edits, or SQL results as Parquet or
  CSV, without entering editing mode. Dataset-JSON files can also be saved
  with their CDISC metadata preserved.
- **Toolbar** — open, attach another file as a table, reload, Save As.
- **Minimap** — scroll-position overview; click or drag it to jump.
- **Dataset-JSON** — CDISC Dataset-JSON v1.1 (`.json` and the streaming
  `.ndjson`) opens with typed columns; edits save back with all CDISC metadata
  (OIDs, labels, formats) preserved verbatim and `decimal` values kept exact.
  Files of 128MB and up transcode single-threaded so opening peaks at
  roughly the file's size in RAM (`.json` is first split into row lines,
  then transcoded like `.ndjson`); smaller files use every core.
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
stamped via `scripts/version.sh set 1.2.3` or `scripts/version.sh bump patch`,
which writes `project.yml` and regenerates the Xcode project.

## Signing

`scripts/signing.sh` resolves one identity per build, in priority order:

1. `$TVTV_IDENTITY` — explicit override (a SHA-1 hash, a full certificate name,
   or `-` to force ad-hoc)
2. a **Developer ID Application** certificate auto-detected from the keychain
3. `-` — ad-hoc, so a Mac with no certificate still builds and runs TVTV

Ad-hoc builds run on the build machine only: they cannot be notarized, and
Gatekeeper rejects them everywhere else. The hardened runtime is on in *every*
configuration (`ENABLE_HARDENED_RUNTIME` in `project.yml`) — notarization
requires it, so a build that breaks under it should fail on the dev loop, not at
release time. Release builds additionally set
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`: TVTV declares no entitlements, and
Xcode's injected default is `get-task-allow`, which the notary service rejects.

Signing stays inside-out and stays Xcode's job — the QuickLook appex is signed
before it is embedded, then sealed by reference in the app's signature. Nothing
re-signs a finished bundle, and nothing uses `--deep`.

## Releasing

```bash
scripts/release.sh              # patch bump: 1.0.0 -> 1.0.1
scripts/release.sh minor        # 1.0.1 -> 1.1.0
scripts/release.sh --dry-run    # everything except commit/tag/push/publish
```

The script runs the tests, stamps the version, builds and signs, asserts the app
*and* the embedded appex are Developer ID signed with the hardened runtime and a
secure timestamp, notarizes and staples the app, packages a stapled `.zip` and a
separately notarized + stapled `.dmg`, then commits, tags, pushes, and creates
the GitHub release with both assets. Any failure after the version stamp reverts
it, leaving the tree as found.

`--dry-run` stops after packaging — nothing is committed, tagged, pushed or
published, and the version stamp is rolled back. It still submits to Apple, so
it genuinely exercises the part that can fail.

One-time setup, alongside `gh auth login` and a Developer ID certificate:

```sh
xcrun notarytool store-credentials tvtv-notary \
    --key <AuthKey_XXXXXXXXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
```

Override the profile name with `$TVTV_NOTARY_PROFILE`. Each release makes two
notary submissions (app, then disk image), typically 1–5 minutes each.

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
