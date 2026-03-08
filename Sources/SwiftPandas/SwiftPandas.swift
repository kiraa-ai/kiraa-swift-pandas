// MARK: - SwiftPandas.swift
// Root namespace declaration for the SwiftPandas library.
//
// SwiftPandas is a native Swift implementation of the Python pandas data analysis library,
// targeting high-performance tabular data manipulation on Apple platforms and Linux. The
// library provides the following core abstractions:
//
// - **DataFrame** — A column-oriented table of heterogeneous, nullable data (analogous to
//   `pandas.DataFrame`). Columns are stored as `Column` enum cases (`.double`, `.int64`,
//   `.bool`, `.string`) backed by `NullableArray` with `BitVector` null masks.
//
// - **Series** — A single column of typed, nullable data with an associated name and index
//   (analogous to `pandas.Series`). Supports element-wise arithmetic, aggregation (sum, mean,
//   min, max, median, std, var), and filtering.
//
// - **Index** — Row labels for DataFrames and Series, supporting label-based lookup.
//
// - **GroupBy** — Split-apply-combine aggregation engine with optional Metal GPU acceleration
//   for large datasets. Supports sum, mean, count, min, max, std, and var.
//
// - **CSV I/O** — A two-tier CSV reader (fast byte-level path + character-based fallback) and
//   a column-wise pre-formatting CSV writer. See `CSVReader.swift` for architecture details.
//
// - **JSON I/O** — JSON serialization/deserialization backed by the CUltraJSON C library.
//
// The library depends on three compiled C targets for performance-critical data structures:
// - **CSkipList** — A skip list for O(log n) windowed median computation.
// - **CKHash** — klib's khash hash tables for fast GroupBy key hashing (FNV-1a).
// - **CUltraJSON** — UltraJSON's core C encoder/decoder for high-throughput JSON I/O.
//
// On Apple platforms (macOS, iOS), the library conditionally links the Accelerate framework
// (via the `ACCELERATE_AVAILABLE` compilation flag) to leverage vDSP for vectorized numeric
// operations on contiguous arrays.

/// Root namespace for the SwiftPandas library.
///
/// `SwiftPandas` is declared as a caseless `enum` (rather than a `struct` or `class`) to
/// prevent instantiation — it serves purely as a namespace for library-wide metadata such
/// as the version string. All functional types (`DataFrame`, `Series`, `GroupBy`, etc.) are
/// defined as top-level public types within the `SwiftPandas` module.
public enum SwiftPandas {
    /// The current semantic version of the SwiftPandas library.
    public static let version = "0.4.0-beta"
}
