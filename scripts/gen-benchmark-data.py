#!/usr/bin/env python3
"""
gen-benchmark-data.py — generate TVTV performance-benchmark fixtures.

WHY these shapes: TVTV pages the grid at a hard-coded pageSize of 10,000
rows with a fixed 22.0pt row pitch, and targets 100M+ row files. The
fixtures below are built to genuinely stress that: a wide ~30-column
table at 100M rows, a table with
long varchar cells (worst case for text layout/measurement), and a
multi-gigabyte plain CSV (worst case for streaming/parse cost).

Usage:
    scripts/gen-benchmark-data.py            # full-scale fixtures (slow, large)
    scripts/gen-benchmark-data.py --smoke    # tiny fixtures for CI / fast local testing
    scripts/gen-benchmark-data.py --smoke --rows 50000   # override smoke row count

Fixtures are written to data/bench/ (git-ignored — see .gitignore).

Full-scale set (default; do NOT run this casually, it is multi-GB and slow):
  wide_100m.parquet    100,000,000 rows x 30 cols, mixed int/float/bool/string/date/timestamp
  longstrings.parquet    5,000,000 rows x 5 cols, long varchar cells (~1.3KB each)
  big.csv                25,000,000 rows x 15 cols, plain multi-GB CSV

Smoke set (--smoke; thousands of rows, seconds to generate):
  smoke_wide.parquet          5,000 rows, same schema as wide_100m.parquet
  smoke_longstrings.parquet   2,000 rows, same schema as longstrings.parquet
  smoke_big.csv                3,000 rows, same schema as big.csv

Smoke fixtures are prefixed with `smoke_` (rather than reusing the full
fixture names) so a smoke run and a full run can coexist in data/bench/
without one clobbering the other.

Generation strategy: prefers the `duckdb` CLI (COPY (SELECT ... FROM
range(N)) TO 'file' (FORMAT ...)) because it streams row generation and
comfortably handles 100M+ rows without materializing them in this process.
Falls back to pyarrow (batched, streaming ParquetWriter / CSV writer) if the
duckdb CLI is not on PATH. The pyarrow fallback works at any scale but is
slower for the full-scale set.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BENCH_DIR = REPO_ROOT / "data" / "bench"

# ---------------------------------------------------------------------------
# Schema definitions
# ---------------------------------------------------------------------------
# "wide" table: ~30 columns of mixed types, matching the kind of file
# TVTV is built to page through (id + numeric + categorical string +
# date/time + bool columns).
WIDE_FULL_ROWS = 100_000_000
WIDE_SMOKE_ROWS = 5_000

LONGSTRINGS_FULL_ROWS = 5_000_000
LONGSTRINGS_SMOKE_ROWS = 2_000

CSV_FULL_ROWS = 25_000_000
CSV_SMOKE_ROWS = 3_000

STATUS_LIST = "['NEW','OPEN','PENDING','CLOSED','ARCHIVED','REJECTED']"
CITY_LIST = (
    "['Copenhagen','Aarhus','Odense','Aalborg','Esbjerg','Randers',"
    "'Kolding','Horsens','Vejle','Roskilde']"
)
CATEGORY_LIST = "['A','B','C','D','E','F','G','H']"


def wide_columns_sql(row_var: str = "i") -> str:
    """~30 mixed-type columns for the 'wide' fixture (wide_100m / smoke_wide)."""
    i = row_var
    cols = [
        f"{i} AS id",
        f"({i} % 2000000)::INTEGER AS int_col_a",
        f"({i} % 500)::INTEGER AS int_col_b",
        f"(({i} * 7) % 100000)::INTEGER AS int_col_c",
        f"(({i} * 31) % 1000)::INTEGER AS int_col_d",
        f"(-1 * ({i} % 10000))::INTEGER AS int_col_e",
        f"({i} % 2147483000)::INTEGER AS int_col_f",
        f"({i} * 1000000000)::BIGINT AS bigint_col_a",
        f"({i})::BIGINT AS bigint_col_b",
        f"({i} % 97) / 3.0 AS double_col_a",
        f"sqrt({i}::DOUBLE + 1) AS double_col_b",
        f"(({i} % 10007) * 1.2345)::DOUBLE AS double_col_c",
        f"({i}::DOUBLE / 3.0) AS double_col_d",
        f"(({i} % 5) = 0)::DOUBLE * 100.0 AS double_col_e",
        f"({i} % 65536)::FLOAT AS float_col_a",
        f"(({i} % 2) = 0) AS bool_col_a",
        f"(({i} % 7) = 0) AS bool_col_b",
        f"{STATUS_LIST}[({i} % 6) + 1] AS status",
        f"{CITY_LIST}[({i} % 10) + 1] AS city",
        f"{CATEGORY_LIST}[({i} % 8) + 1] AS category",
        f"'SKU-' || lpad(({i} % 999999)::VARCHAR, 6, '0') AS sku",
        f"'user_' || ({i} % 250000)::VARCHAR AS username",
        f"md5({i}::VARCHAR) AS hash_col",
        f"(DATE '2000-01-01' + ({i} % 9500)::INTEGER)::DATE AS date_col_a",
        f"(DATE '2015-06-01' + ({i} % 3600)::INTEGER)::DATE AS date_col_b",
        f"(TIMESTAMP '2000-01-01 00:00:00' + INTERVAL ({i} % 800000) SECOND) AS ts_col_a",
        f"(TIMESTAMP '2020-01-01 00:00:00' + INTERVAL ({i} % 60000000) SECOND) AS ts_col_b",
        f"({i} % 3 = 0) AS flag_a",
        f"NULL::INTEGER AS mostly_null_int",
        f"CASE WHEN ({i} % 500) = 0 THEN 'special-' || {i}::VARCHAR ELSE NULL END AS sparse_text",
    ]
    return ",\n    ".join(cols)


def longstrings_columns_sql(row_var: str = "i") -> str:
    """Columns with long varchar cells — worst case for text layout/measurement."""
    i = row_var
    # repeat(md5(...), n) gives deterministic, per-row-varying long text
    # without needing a random() seed (keeps generation reproducible).
    return ",\n    ".join(
        [
            f"{i} AS id",
            f"{CATEGORY_LIST}[({i} % 8) + 1] AS category",
            f"repeat(md5({i}::VARCHAR) || ' ', 40) AS note",
            f"repeat(md5(({i}+1)::VARCHAR) || ' ', 80) AS description",
            f"repeat(md5(({i}+2)::VARCHAR), 4) AS short_blob",
        ]
    )


def csv_columns_sql(row_var: str = "i") -> str:
    """Narrower numeric+string schema for the multi-GB plain-CSV fixture."""
    i = row_var
    cols = [
        f"{i} AS id",
        f"({i} % 2000000)::INTEGER AS int_col_a",
        f"({i} % 500)::INTEGER AS int_col_b",
        f"(({i} % 97) / 3.0) AS double_col_a",
        f"sqrt({i}::DOUBLE + 1) AS double_col_b",
        f"{STATUS_LIST}[({i} % 6) + 1] AS status",
        f"{CITY_LIST}[({i} % 10) + 1] AS city",
        f"'SKU-' || lpad(({i} % 999999)::VARCHAR, 6, '0') AS sku",
        f"'user_' || ({i} % 250000)::VARCHAR AS username",
        f"(DATE '2000-01-01' + ({i} % 9500)::INTEGER)::DATE AS date_col_a",
        f"(TIMESTAMP '2020-01-01 00:00:00' + INTERVAL ({i} % 60000000) SECOND) AS ts_col_a",
        f"({i} % 2 = 0) AS bool_col_a",
        f"md5({i}::VARCHAR) AS hash_col",
        f"({i} % 10007) * 1.2345 AS double_col_c",
        f"'note text for row ' || {i}::VARCHAR AS note",
    ]
    return ",\n    ".join(cols)


# ---------------------------------------------------------------------------
# duckdb-CLI backend
# ---------------------------------------------------------------------------
def duckdb_available() -> bool:
    return shutil.which("duckdb") is not None


def duckdb_exec(sql: str) -> None:
    subprocess.run(["duckdb", ":memory:", sql], check=True)


def duckdb_generate_parquet(rows: int, columns_sql: str, out_path: Path) -> None:
    sql = (
        f"COPY (\n  SELECT\n    {columns_sql}\n  FROM range({rows}) AS t(i)\n"
        f") TO '{out_path}' (FORMAT PARQUET);"
    )
    duckdb_exec(sql)


def duckdb_generate_csv(rows: int, columns_sql: str, out_path: Path) -> None:
    sql = (
        f"COPY (\n  SELECT\n    {columns_sql}\n  FROM range({rows}) AS t(i)\n"
        f") TO '{out_path}' (FORMAT CSV, HEADER TRUE);"
    )
    duckdb_exec(sql)


def duckdb_row_count(path: Path) -> int:
    reader = "read_parquet" if path.suffix == ".parquet" else "read_csv_auto"
    out = subprocess.run(
        ["duckdb", ":memory:", "-csv", "-noheader",
         f"SELECT count(*) FROM {reader}('{path}');"],
        check=True, capture_output=True, text=True,
    )
    return int(out.stdout.strip())


# ---------------------------------------------------------------------------
# pyarrow fallback backend (used only if duckdb CLI is not on PATH)
# ---------------------------------------------------------------------------
def pyarrow_generate(rows: int, out_path: Path, kind: str) -> None:
    import pyarrow as pa
    import pyarrow.parquet as pq
    import pyarrow.csv as pcsv
    import hashlib
    import datetime

    batch_size = 500_000
    statuses = ["NEW", "OPEN", "PENDING", "CLOSED", "ARCHIVED", "REJECTED"]
    cities = ["Copenhagen", "Aarhus", "Odense", "Aalborg", "Esbjerg",
              "Randers", "Kolding", "Horsens", "Vejle", "Roskilde"]
    categories = ["A", "B", "C", "D", "E", "F", "G", "H"]

    def batch_iter():
        for start in range(0, rows, batch_size):
            n = min(batch_size, rows - start)
            idx = list(range(start, start + n))
            if kind == "wide":
                yield pa.record_batch(
                    {
                        "id": pa.array(idx, type=pa.int64()),
                        "int_col_a": pa.array([i % 2000000 for i in idx], type=pa.int32()),
                        "status": pa.array([statuses[i % 6] for i in idx]),
                        "city": pa.array([cities[i % 10] for i in idx]),
                        "category": pa.array([categories[i % 8] for i in idx]),
                        "double_col_a": pa.array([(i % 97) / 3.0 for i in idx], type=pa.float64()),
                        "hash_col": pa.array([hashlib.md5(str(i).encode()).hexdigest() for i in idx]),
                        "date_col_a": pa.array(
                            [datetime.date(2000, 1, 1) + datetime.timedelta(days=i % 9500) for i in idx]
                        ),
                    }
                )
            elif kind == "longstrings":
                yield pa.record_batch(
                    {
                        "id": pa.array(idx, type=pa.int64()),
                        "category": pa.array([categories[i % 8] for i in idx]),
                        "note": pa.array(
                            [(hashlib.md5(str(i).encode()).hexdigest() + " ") * 40 for i in idx]
                        ),
                        "description": pa.array(
                            [(hashlib.md5(str(i + 1).encode()).hexdigest() + " ") * 80 for i in idx]
                        ),
                    }
                )
            else:  # csv
                yield pa.record_batch(
                    {
                        "id": pa.array(idx, type=pa.int64()),
                        "int_col_a": pa.array([i % 2000000 for i in idx], type=pa.int32()),
                        "status": pa.array([statuses[i % 6] for i in idx]),
                        "city": pa.array([cities[i % 10] for i in idx]),
                        "note": pa.array([f"note text for row {i}" for i in idx]),
                    }
                )

    batches = list(batch_iter())
    table = pa.Table.from_batches(batches)
    if out_path.suffix == ".parquet":
        pq.write_table(table, out_path)
    else:
        pcsv.write_csv(table, out_path)


def pyarrow_row_count(path: Path) -> int:
    if path.suffix == ".parquet":
        import pyarrow.parquet as pq
        return pq.ParquetFile(path).metadata.num_rows
    else:
        with open(path, "rb") as f:
            return sum(1 for _ in f) - 1  # minus header


# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------
def human_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size < 1024.0:
            return f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{size:.1f}PB"


def report_fixture(path: Path, row_count) -> None:
    size = path.stat().st_size
    print(f"  {path.name:28s} rows={row_count:>12,}  size={human_size(size):>10s}  ({path})")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--smoke", action="store_true", help="generate tiny fixtures for CI/fast local testing")
    parser.add_argument("--out-dir", default=str(BENCH_DIR), help="output directory (default: data/bench)")
    parser.add_argument("--rows", type=int, default=None,
                         help="override the row count for ALL three fixtures (advanced/debugging use)")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    if args.smoke:
        prefix = "smoke_"
        wide_rows = args.rows or WIDE_SMOKE_ROWS
        long_rows = args.rows or LONGSTRINGS_SMOKE_ROWS
        csv_rows = args.rows or CSV_SMOKE_ROWS
        wide_name = "smoke_wide.parquet"
    else:
        prefix = ""
        wide_rows = args.rows or WIDE_FULL_ROWS
        long_rows = args.rows or LONGSTRINGS_FULL_ROWS
        csv_rows = args.rows or CSV_FULL_ROWS
        wide_name = "wide_100m.parquet"

    long_name = f"{prefix}longstrings.parquet"
    csv_name = f"{prefix}big.csv"

    wide_path = out_dir / wide_name
    long_path = out_dir / long_name
    csv_path = out_dir / csv_name

    use_duckdb = duckdb_available()
    backend = "duckdb CLI" if use_duckdb else "pyarrow (fallback — duckdb CLI not found on PATH)"
    print(f"gen-benchmark-data: backend = {backend}")
    print(f"gen-benchmark-data: mode = {'smoke' if args.smoke else 'full'}, output dir = {out_dir}")

    t0 = time.time()

    print(f"\n[1/3] wide table: {wide_rows:,} rows x 30 cols -> {wide_path.name}")
    if use_duckdb:
        duckdb_generate_parquet(wide_rows, wide_columns_sql(), wide_path)
    else:
        pyarrow_generate(wide_rows, wide_path, "wide")

    print(f"[2/3] long-strings table: {long_rows:,} rows x 5 cols -> {long_path.name}")
    if use_duckdb:
        duckdb_generate_parquet(long_rows, longstrings_columns_sql(), long_path)
    else:
        pyarrow_generate(long_rows, long_path, "longstrings")

    print(f"[3/3] csv: {csv_rows:,} rows x 15 cols -> {csv_path.name}")
    if use_duckdb:
        duckdb_generate_csv(csv_rows, csv_columns_sql(), csv_path)
    else:
        pyarrow_generate(csv_rows, csv_path, "csv")

    elapsed = time.time() - t0

    print(f"\nDone in {elapsed:.1f}s. Fixtures:")
    for path, expected_rows in [(wide_path, wide_rows), (long_path, long_rows), (csv_path, csv_rows)]:
        if use_duckdb:
            actual_rows = duckdb_row_count(path)
        else:
            actual_rows = pyarrow_row_count(path)
        if actual_rows != expected_rows:
            print(f"  WARNING: {path.name} expected {expected_rows} rows, found {actual_rows}", file=sys.stderr)
        report_fixture(path, actual_rows)

    return 0


if __name__ == "__main__":
    sys.exit(main())
