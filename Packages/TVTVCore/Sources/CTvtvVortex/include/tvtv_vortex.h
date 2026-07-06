/*
 * tvtv_vortex.h — C ABI for the `tvtv-vortex` Rust staticlib, so TVTVCore's
 * `VortexReader` can call it. Signatures match the crate's src/lib.rs. The
 * symbols are resolved at the final app/extension link step (the Xcode
 * targets link rust/tvtv-vortex/target/release/libtvtv_vortex.a).
 */
#ifndef TVTV_VORTEX_H
#define TVTV_VORTEX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a materialized (possibly row-capped) preview. */
typedef struct tvtv_vortex_preview_t tvtv_vortex_preview_t;

/* Parse `path`, materialize up to `row_cap` rows. Returns 0 on success (and
 * sets *out_handle); non-zero on failure (sets *out_error, caller-owned). */
int32_t tvtv_vortex_preview(const char *path,
                            int64_t row_cap,
                            tvtv_vortex_preview_t **out_handle,
                            char **out_error);

/* Free a preview handle (and every handle-owned string it returned). */
void tvtv_vortex_preview_free(tvtv_vortex_preview_t *handle);

uint64_t tvtv_vortex_preview_column_count(const tvtv_vortex_preview_t *handle);
uint64_t tvtv_vortex_preview_row_count(const tvtv_vortex_preview_t *handle);
uint64_t tvtv_vortex_preview_total_rows(const tvtv_vortex_preview_t *handle);
uint8_t tvtv_vortex_preview_truncated(const tvtv_vortex_preview_t *handle);

/* Handle-owned strings (valid until tvtv_vortex_preview_free); do NOT free
 * individually. Return NULL on NULL handle / out-of-bounds index. */
const char *tvtv_vortex_preview_column_name(const tvtv_vortex_preview_t *handle,
                                            uint64_t column_index);
const char *tvtv_vortex_preview_column_type(const tvtv_vortex_preview_t *handle,
                                            uint64_t column_index);
const char *tvtv_vortex_preview_cell(const tvtv_vortex_preview_t *handle,
                                     uint64_t row_index,
                                     uint64_t column_index);

/* Convert the Vortex file at `src_path` to Parquet at `dest_path`. Returns 0
 * on success; non-zero on failure (sets *out_error, caller-owned). */
int32_t tvtv_vortex_to_parquet(const char *src_path,
                               const char *dest_path,
                               char **out_error);

/* Free a caller-owned string from an `out_error` out-param. */
void tvtv_vortex_string_free(char *str);

#ifdef __cplusplus
}
#endif

#endif /* TVTV_VORTEX_H */
