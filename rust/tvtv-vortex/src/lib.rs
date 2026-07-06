//! `tvtv-vortex`: C FFI staticlib exposing Vortex-format read/convert
//! support to `TVTVCore` (DuckDB cannot read Vortex natively).
//!
//! The two work functions (`tvtv_vortex_preview`, `tvtv_vortex_to_parquet`)
//! open a Vortex file with `vortex-file`, convert Vortex arrays to Arrow,
//! and either materialize a row-capped preview (with every cell
//! pre-formatted to a display string) or stream the whole file out as
//! Parquet. The getters read from the opaque, heap-owned handle;
//! `tvtv_vortex_preview_free` drops it (freeing every handle-owned string),
//! and `tvtv_vortex_string_free` frees a caller-owned `out_error` string.
//!
//! Ownership:
//!   - Handle-owned strings (`_column_name`/`_column_type`/`_cell`) are
//!     `CString`s stored inside the handle; getters return `.as_ptr()` and
//!     they stay valid until `tvtv_vortex_preview_free`.
//!   - Caller-owned `out_error` strings are heap `CString`s via `into_raw`,
//!     released once by `tvtv_vortex_string_free`.

#![allow(non_camel_case_types)]

use std::ffi::{CStr, CString};
use std::ops::Range;
use std::os::raw::c_char;
use std::ptr;

use arrow::array::RecordBatch;
use arrow::datatypes::{DataType, SchemaRef};
use arrow::util::display::{ArrayFormatter, FormatOptions};

use vortex::VortexSessionDefault;
use vortex::array::stream::ArrayStreamExt;
use vortex::array::ArrayRef;
use vortex::file::{OpenOptionsSessionExt, VortexFile};
use vortex::session::VortexSession;

/// Opaque handle to a loaded, row-capped preview. Fully owns its string
/// buffers; every getter reads through it and it is freed exactly once by
/// `tvtv_vortex_preview_free`.
pub struct tvtv_vortex_preview_t {
    column_count: u64,
    row_count: u64,
    total_rows: u64,
    truncated: bool,
    /// One `CString` per column (NUL-terminated column name).
    column_names: Vec<CString>,
    /// One `CString` per column (DuckDB-style type name).
    column_types: Vec<CString>,
    /// Row-major cells: index = row * column_count + col. Null -> "".
    cells: Vec<CString>,
}

/// Write a heap-allocated, NUL-terminated C string into `*out_error`,
/// per the caller-owned ownership contract described above. No-op if
/// `out_error` is NULL.
fn set_error(out_error: *mut *mut c_char, message: &str) {
    if out_error.is_null() {
        return;
    }
    let c_message = CString::new(message)
        .unwrap_or_else(|_| CString::new("tvtv_vortex: error").unwrap());
    unsafe {
        *out_error = c_message.into_raw();
    }
}

/// Map an Arrow `DataType` to the DuckDB-style logical type name reported
/// via `tvtv_vortex_preview_column_type`. Falls back to the Arrow debug
/// spelling for exotic nested types.
fn duckdb_type_name(dt: &DataType) -> String {
    match dt {
        DataType::Boolean => "BOOLEAN".to_string(),
        DataType::Int8 => "TINYINT".to_string(),
        DataType::Int16 => "SMALLINT".to_string(),
        DataType::Int32 => "INTEGER".to_string(),
        DataType::Int64 => "BIGINT".to_string(),
        DataType::UInt8 => "UTINYINT".to_string(),
        DataType::UInt16 => "USMALLINT".to_string(),
        DataType::UInt32 => "UINTEGER".to_string(),
        DataType::UInt64 => "UBIGINT".to_string(),
        DataType::Float16 | DataType::Float32 => "FLOAT".to_string(),
        DataType::Float64 => "DOUBLE".to_string(),
        DataType::Utf8 | DataType::LargeUtf8 | DataType::Utf8View => "VARCHAR".to_string(),
        DataType::Binary
        | DataType::LargeBinary
        | DataType::BinaryView
        | DataType::FixedSizeBinary(_) => "BLOB".to_string(),
        DataType::Date32 | DataType::Date64 => "DATE".to_string(),
        DataType::Time32(_) | DataType::Time64(_) => "TIME".to_string(),
        DataType::Timestamp(_, _) => "TIMESTAMP".to_string(),
        DataType::Decimal32(_, _)
        | DataType::Decimal64(_, _)
        | DataType::Decimal128(_, _)
        | DataType::Decimal256(_, _) => "DECIMAL".to_string(),
        DataType::Null => "VARCHAR".to_string(),
        // Nested / exotic types: no clean DuckDB scalar name — expose the
        // Arrow spelling uppercased so it's at least legible in the viewer.
        other => format!("{other:?}").to_uppercase(),
    }
}

/// Build a fresh Tokio runtime for the synchronous FFI boundary. Errors are
/// surfaced as `VortexResult`-friendly strings by the callers.
fn new_runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Runtime::new().map_err(|e| format!("failed to create Tokio runtime: {e}"))
}

/// Open a Vortex file at `path` on the current async runtime.
async fn open_vortex(path: &str) -> Result<(VortexFile, VortexSession), String> {
    let session = VortexSession::default();
    let file = session
        .open_options()
        .open_path(path)
        .await
        .map_err(|e| format!("failed to open Vortex file '{path}': {e}"))?;
    Ok((file, session))
}

/// Read the (row-capped) contents of an already-opened Vortex file into a
/// single Arrow `RecordBatch`. `row_range` limits which rows are scanned.
async fn read_record_batch(
    file: &VortexFile,
    row_range: Range<u64>,
) -> Result<RecordBatch, String> {
    let array: ArrayRef = file
        .scan()
        .map_err(|e| format!("failed to start scan: {e}"))?
        .with_row_range(row_range)
        .into_array_stream()
        .map_err(|e| format!("failed to build array stream: {e}"))?
        .read_all()
        .await
        .map_err(|e| format!("failed to read Vortex arrays: {e}"))?;

    RecordBatch::try_from(array.as_ref())
        .map_err(|e| format!("failed to convert Vortex array to Arrow RecordBatch: {e}"))
}

/// Core preview logic, returning either a populated handle or an error string.
fn build_preview(path: &str, row_cap: i64) -> Result<tvtv_vortex_preview_t, String> {
    let rt = new_runtime()?;
    rt.block_on(async move {
        let (file, _session) = open_vortex(path).await?;
        let total_rows = file.row_count();

        // row_cap semantics: treat a negative cap as zero, and clamp to
        // the file's true row count.
        let cap = if row_cap < 0 {
            0u64
        } else {
            (row_cap as u64).min(total_rows)
        };

        let batch = read_record_batch(&file, 0..cap).await?;

        let schema: SchemaRef = batch.schema();
        let column_count = schema.fields().len() as u64;
        let row_count = batch.num_rows() as u64;

        let mut column_names = Vec::with_capacity(schema.fields().len());
        let mut column_types = Vec::with_capacity(schema.fields().len());
        for field in schema.fields() {
            column_names.push(to_cstring(field.name()));
            column_types.push(to_cstring(&duckdb_type_name(field.data_type())));
        }

        // Pre-format every cell to a display string, row-major. Nulls -> "".
        let opts = FormatOptions::default().with_null("");
        let mut formatters = Vec::with_capacity(batch.num_columns());
        for col in batch.columns() {
            let f = ArrayFormatter::try_new(col.as_ref(), &opts)
                .map_err(|e| format!("failed to build Arrow formatter: {e}"))?;
            formatters.push(f);
        }

        let mut cells = Vec::with_capacity((row_count as usize) * (column_count as usize));
        for row in 0..(row_count as usize) {
            for f in &formatters {
                cells.push(to_cstring(&f.value(row).to_string()));
            }
        }

        Ok(tvtv_vortex_preview_t {
            column_count,
            row_count,
            total_rows,
            truncated: row_count < total_rows,
            column_names,
            column_types,
            cells,
        })
    })
}

/// Build a `CString`, replacing any embedded NUL (illegal in C strings) with
/// the Unicode replacement char so this can never fail across the boundary.
fn to_cstring(s: &str) -> CString {
    match CString::new(s) {
        Ok(c) => c,
        Err(_) => {
            let cleaned: String = s.chars().map(|c| if c == '\0' { '\u{FFFD}' } else { c }).collect();
            CString::new(cleaned).unwrap_or_else(|_| CString::new("").unwrap())
        }
    }
}

/// Parse `path` as a Vortex file and materialize up to `row_cap` rows.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview(
    path: *const c_char,
    row_cap: i64,
    out_handle: *mut *mut tvtv_vortex_preview_t,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_handle.is_null() {
        unsafe {
            *out_handle = ptr::null_mut();
        }
    }
    if path.is_null() {
        set_error(out_error, "tvtv_vortex_preview: path is NULL");
        return 1;
    }
    if out_handle.is_null() {
        set_error(out_error, "tvtv_vortex_preview: out_handle is NULL");
        return 1;
    }
    let path = unsafe { CStr::from_ptr(path) }.to_string_lossy().into_owned();

    match build_preview(&path, row_cap) {
        Ok(handle) => {
            let boxed = Box::new(handle);
            unsafe {
                *out_handle = Box::into_raw(boxed);
            }
            0
        }
        Err(msg) => {
            set_error(out_error, &format!("tvtv_vortex_preview: {msg}"));
            1
        }
    }
}

/// Free a preview handle (and every handle-owned string). No-op on NULL.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_free(handle: *mut tvtv_vortex_preview_t) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(handle));
    }
}

/// Number of columns. 0 if `handle == NULL`.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_column_count(handle: *const tvtv_vortex_preview_t) -> u64 {
    match unsafe { handle.as_ref() } {
        Some(h) => h.column_count,
        None => 0,
    }
}

/// Rows actually materialized (<= row_cap, <= total_rows). 0 if NULL.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_row_count(handle: *const tvtv_vortex_preview_t) -> u64 {
    match unsafe { handle.as_ref() } {
        Some(h) => h.row_count,
        None => 0,
    }
}

/// Total rows in the underlying source file. 0 if NULL.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_total_rows(handle: *const tvtv_vortex_preview_t) -> u64 {
    match unsafe { handle.as_ref() } {
        Some(h) => h.total_rows,
        None => 0,
    }
}

/// Whether the preview was truncated. 0 (false) if NULL.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_truncated(handle: *const tvtv_vortex_preview_t) -> u8 {
    match unsafe { handle.as_ref() } {
        Some(h) => h.truncated as u8,
        None => 0,
    }
}

/// Column name at `column_index`, handle-owned. NULL if out of bounds/NULL.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_column_name(
    handle: *const tvtv_vortex_preview_t,
    column_index: u64,
) -> *const c_char {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return ptr::null();
    };
    match h.column_names.get(column_index as usize) {
        Some(c) => c.as_ptr(),
        None => ptr::null(),
    }
}

/// Column type NAME at `column_index`, handle-owned. NULL if out of bounds.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_column_type(
    handle: *const tvtv_vortex_preview_t,
    column_index: u64,
) -> *const c_char {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return ptr::null();
    };
    match h.column_types.get(column_index as usize) {
        Some(c) => c.as_ptr(),
        None => ptr::null(),
    }
}

/// Pre-formatted cell at (row_index, column_index), handle-owned. NULL if any
/// index is out of bounds or the flattened index falls outside the vector.
#[no_mangle]
pub extern "C" fn tvtv_vortex_preview_cell(
    handle: *const tvtv_vortex_preview_t,
    row_index: u64,
    column_index: u64,
) -> *const c_char {
    let Some(h) = (unsafe { handle.as_ref() }) else {
        return ptr::null();
    };
    if row_index >= h.row_count || column_index >= h.column_count {
        return ptr::null();
    }
    let idx = row_index
        .checked_mul(h.column_count)
        .and_then(|v| v.checked_add(column_index));
    match idx.and_then(|i| h.cells.get(i as usize)) {
        Some(c) => c.as_ptr(),
        None => ptr::null(),
    }
}

/// Convert the whole Vortex file at `src_path` to a Parquet file at
/// `dest_path`. Returns 0 on success, non-zero + `out_error` on failure.
#[no_mangle]
pub extern "C" fn tvtv_vortex_to_parquet(
    src_path: *const c_char,
    dest_path: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if src_path.is_null() {
        set_error(out_error, "tvtv_vortex_to_parquet: src_path is NULL");
        return 1;
    }
    if dest_path.is_null() {
        set_error(out_error, "tvtv_vortex_to_parquet: dest_path is NULL");
        return 1;
    }
    let src = unsafe { CStr::from_ptr(src_path) }.to_string_lossy().into_owned();
    let dest = unsafe { CStr::from_ptr(dest_path) }.to_string_lossy().into_owned();

    match convert_to_parquet(&src, &dest) {
        Ok(()) => 0,
        Err(msg) => {
            set_error(out_error, &format!("tvtv_vortex_to_parquet: {msg}"));
            1
        }
    }
}

fn convert_to_parquet(src: &str, dest: &str) -> Result<(), String> {
    use parquet::arrow::ArrowWriter;
    use std::fs::File;

    let rt = new_runtime()?;
    rt.block_on(async move {
        let (file, _session) = open_vortex(src).await?;
        let total = file.row_count();
        let batch = read_record_batch(&file, 0..total).await?;

        let out = File::create(dest)
            .map_err(|e| format!("failed to create Parquet file '{dest}': {e}"))?;
        let mut writer = ArrowWriter::try_new(out, batch.schema(), None)
            .map_err(|e| format!("failed to create Parquet writer: {e}"))?;
        writer
            .write(&batch)
            .map_err(|e| format!("failed to write Parquet batch: {e}"))?;
        writer
            .close()
            .map_err(|e| format!("failed to finalize Parquet file: {e}"))?;
        Ok(())
    })
}

/// Free a heap C string previously written into an `out_error` out-param.
/// Safe to call with `str == NULL` (no-op).
#[no_mangle]
pub extern "C" fn tvtv_vortex_string_free(str: *mut c_char) {
    if str.is_null() {
        return;
    }
    unsafe {
        drop(CString::from_raw(str));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use arrow::array::{Float64Array, Int64Array, StringArray};
    use arrow::datatypes::{DataType, Field, Schema};
    use std::ffi::CString;
    use std::sync::Arc;
    use vortex::array::arrow::FromArrowArray;
    use vortex::file::WriteOptionsSessionExt;

    /// Build a small Arrow RecordBatch with Int64/Utf8/Float64 columns and
    /// some nulls, write it to a temp `.vtx` via the Vortex writer, then
    /// exercise both the preview path and the to_parquet path end-to-end.
    #[test]
    fn round_trip_preview_and_parquet() {
        let schema = Arc::new(Schema::new(vec![
            Field::new("id", DataType::Int64, false),
            Field::new("name", DataType::Utf8, true),
            Field::new("score", DataType::Float64, true),
        ]));

        let ids = Int64Array::from(vec![1, 2, 3, 4]);
        let names = StringArray::from(vec![Some("alice"), None, Some("carol"), Some("dave")]);
        let scores = Float64Array::from(vec![Some(1.5), Some(2.5), None, Some(4.5)]);

        let batch = RecordBatch::try_new(
            schema,
            vec![Arc::new(ids), Arc::new(names), Arc::new(scores)],
        )
        .unwrap();

        // Write the batch out as a Vortex file.
        let dir = std::env::temp_dir();
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let vtx_path = dir.join(format!("tvtv_roundtrip_{stamp}.vtx"));

        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let session = VortexSession::default();
            let varray = ArrayRef::from_arrow(batch.clone(), false).unwrap();
            let mut f = tokio::fs::File::create(&vtx_path).await.unwrap();
            session
                .write_options()
                .write(&mut f, varray.to_array_stream())
                .await
                .unwrap();
            tokio::io::AsyncWriteExt::flush(&mut f).await.unwrap();
            f.sync_all().await.unwrap();
        });

        let vtx_c = CString::new(vtx_path.to_str().unwrap()).unwrap();

        // (a) Preview path — cap at 3 rows out of 4.
        let mut handle: *mut tvtv_vortex_preview_t = ptr::null_mut();
        let mut err: *mut c_char = ptr::null_mut();
        let rc = tvtv_vortex_preview(vtx_c.as_ptr(), 3, &mut handle, &mut err);
        assert_eq!(rc, 0, "preview failed: {}", unsafe { err_to_string(err) });
        assert!(!handle.is_null());

        assert_eq!(tvtv_vortex_preview_column_count(handle), 3);
        assert_eq!(tvtv_vortex_preview_row_count(handle), 3);
        assert_eq!(tvtv_vortex_preview_total_rows(handle), 4);
        assert_eq!(tvtv_vortex_preview_truncated(handle), 1);

        assert_eq!(cstr(tvtv_vortex_preview_column_name(handle, 0)), "id");
        assert_eq!(cstr(tvtv_vortex_preview_column_name(handle, 1)), "name");
        assert_eq!(cstr(tvtv_vortex_preview_column_name(handle, 2)), "score");

        assert_eq!(cstr(tvtv_vortex_preview_column_type(handle, 0)), "BIGINT");
        assert_eq!(cstr(tvtv_vortex_preview_column_type(handle, 1)), "VARCHAR");
        assert_eq!(cstr(tvtv_vortex_preview_column_type(handle, 2)), "DOUBLE");

        // Cell values, including null formatting -> "".
        assert_eq!(cstr(tvtv_vortex_preview_cell(handle, 0, 0)), "1");
        assert_eq!(cstr(tvtv_vortex_preview_cell(handle, 0, 1)), "alice");
        assert_eq!(cstr(tvtv_vortex_preview_cell(handle, 1, 1)), ""); // null name
        assert_eq!(cstr(tvtv_vortex_preview_cell(handle, 2, 2)), ""); // null score
        assert_eq!(cstr(tvtv_vortex_preview_cell(handle, 2, 0)), "3");

        // Out-of-bounds -> NULL.
        assert!(tvtv_vortex_preview_cell(handle, 3, 0).is_null());
        assert!(tvtv_vortex_preview_column_name(handle, 9).is_null());

        tvtv_vortex_preview_free(handle);

        // (b) to_parquet path — convert the whole file and re-read it.
        let pq_path = dir.join(format!("tvtv_roundtrip_{stamp}.parquet"));
        let pq_c = CString::new(pq_path.to_str().unwrap()).unwrap();
        let mut err2: *mut c_char = ptr::null_mut();
        let rc2 = tvtv_vortex_to_parquet(vtx_c.as_ptr(), pq_c.as_ptr(), &mut err2);
        assert_eq!(rc2, 0, "to_parquet failed: {}", unsafe { err_to_string(err2) });

        let pq_file = std::fs::File::open(&pq_path).unwrap();
        let reader =
            parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder::try_new(pq_file)
                .unwrap()
                .build()
                .unwrap();
        let mut total = 0usize;
        let mut first_id: Option<i64> = None;
        for rb in reader {
            let rb = rb.unwrap();
            if first_id.is_none() && rb.num_rows() > 0 {
                let ids = rb
                    .column(0)
                    .as_any()
                    .downcast_ref::<Int64Array>()
                    .unwrap();
                first_id = Some(ids.value(0));
            }
            total += rb.num_rows();
        }
        assert_eq!(total, 4, "parquet should have all 4 rows");
        assert_eq!(first_id, Some(1));

        let _ = std::fs::remove_file(&vtx_path);
        let _ = std::fs::remove_file(&pq_path);
    }

    fn cstr(p: *const c_char) -> String {
        assert!(!p.is_null(), "unexpected NULL cell/name pointer");
        unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
    }

    unsafe fn err_to_string(p: *const c_char) -> String {
        if p.is_null() {
            "<no error message>".to_string()
        } else {
            CStr::from_ptr(p).to_string_lossy().into_owned()
        }
    }
}
