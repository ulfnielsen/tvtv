//! `parquet_to_vtx` — small fixture generator: read a Parquet file into Arrow
//! RecordBatches and write them out as a single Vortex (`.vtx`) file, using
//! the same write path as the crate's round-trip test
//! (`ArrayRef::from_arrow` -> `session.write_options().write(...)` on a
//! `tokio::fs::File`, with an explicit flush + `sync_all`).
//!
//! Usage:
//!   cargo run --release --offline --example parquet_to_vtx -- <src.parquet> <dest.vtx>

use std::fs::File;

use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
use tokio::io::AsyncWriteExt;

use vortex::VortexSessionDefault;
use vortex::array::arrays::ChunkedArray;
use vortex::array::arrow::FromArrowArray;
use vortex::array::{ArrayRef, IntoArray};
use vortex::file::WriteOptionsSessionExt;
use vortex::session::VortexSession;

fn main() {
    let mut args = std::env::args().skip(1);
    let src = args.next().unwrap_or_else(|| {
        eprintln!("usage: parquet_to_vtx <src.parquet> <dest.vtx>");
        std::process::exit(2);
    });
    let dest = args.next().unwrap_or_else(|| {
        eprintln!("usage: parquet_to_vtx <src.parquet> <dest.vtx>");
        std::process::exit(2);
    });

    if let Err(e) = run(&src, &dest) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run(src: &str, dest: &str) -> Result<(), String> {
    // Read the entire Parquet file into Arrow RecordBatches.
    let file = File::open(src).map_err(|e| format!("open parquet '{src}': {e}"))?;
    let reader = ParquetRecordBatchReaderBuilder::try_new(file)
        .map_err(|e| format!("parquet reader: {e}"))?
        .build()
        .map_err(|e| format!("parquet reader build: {e}"))?;

    let mut chunks: Vec<ArrayRef> = Vec::new();
    let mut total_rows: usize = 0;
    for batch in reader {
        let batch = batch.map_err(|e| format!("read batch: {e}"))?;
        total_rows += batch.num_rows();
        // Non-nullable top-level struct so the round-trip preview
        // (RecordBatch::try_from, which requires an all-valid struct) works.
        let arr = ArrayRef::from_arrow(batch, false)
            .map_err(|e| format!("arrow -> vortex: {e}"))?;
        chunks.push(arr);
    }

    if chunks.is_empty() {
        return Err("parquet file produced no record batches".to_string());
    }

    // Concatenate the per-batch struct arrays into a single chunked array.
    let dtype = chunks[0].dtype().clone();
    let array: ArrayRef = if chunks.len() == 1 {
        chunks.remove(0)
    } else {
        ChunkedArray::try_new(chunks, dtype)
            .map_err(|e| format!("chunk concat: {e}"))?
            .into_array()
    };

    // Write the Vortex file on a Tokio runtime (same path as the crate test).
    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio runtime: {e}"))?;
    rt.block_on(async move {
        let session = VortexSession::default();
        let mut f = tokio::fs::File::create(dest)
            .await
            .map_err(|e| format!("create '{dest}': {e}"))?;
        session
            .write_options()
            .write(&mut f, array.to_array_stream())
            .await
            .map_err(|e| format!("vortex write: {e}"))?;
        f.flush().await.map_err(|e| format!("flush: {e}"))?;
        f.sync_all().await.map_err(|e| format!("sync_all: {e}"))?;
        Ok::<(), String>(())
    })?;

    println!("wrote {dest} ({total_rows} rows) from {src}");
    Ok(())
}
