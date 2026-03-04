# SwiftPandas

A native Swift port of the [Python pandas](https://github.com/pandas-dev/pandas) data analysis library, built as a Swift Package Manager (SPM) library.

SwiftPandas provides `DataFrame`, `Series`, and `Index` types for tabular data manipulation in Swift, with compiled C libraries (khash, skiplist, UltraJSON) for performance-critical operations.

## Authors

- **Markos Abdallah**
- **Errol Brandt**

## Attribution

This project is a Swift port of [pandas](https://github.com/pandas-dev/pandas), the powerful Python data analysis library created by **Wes McKinney** and maintained by the [PyData Development Team](https://github.com/pandas-dev). The original pandas library is licensed under the [BSD 3-Clause License](https://github.com/pandas-dev/pandas/blob/main/LICENSE).

The following vendored C libraries from the pandas project are compiled directly as SPM targets:

- **[klib (khash)](https://github.com/attractivechaos/klib)** — Generic hash table library by Attractive Chaos (MIT License)
- **[UltraJSON](https://github.com/ultrajson/ultrajson)** — Ultra-fast JSON encoder/decoder by Jonas Tarnstrom / ESN Social Software AB (BSD License)
- **Skiplist** — Skiplist data structure, ported from Raymond Hettinger's original Python recipe by Wes McKinney (BSD License)

## Features

### Core Types
- **`DataFrame`** — 2D labeled tabular data with column-oriented storage
- **`Series`** — 1D labeled array with numeric, string, and boolean support
- **`Index`** — Label-based axis indexing (`RangeIndex`, `StringIndex`, `Int64Index`)

### Data Types
- All numeric columns default to `Double` for type consistency
- `NullableArray<T>` with `BitVector` validity bitmaps for NA support
- `NativeArray<T>` with copy-on-write semantics
- `StringArray` for string data with NA handling
- `Column` enum for type-erased heterogeneous DataFrame columns

### Operations
- **Aggregations**: `sum()`, `mean()`, `std()`, `min()`, `max()`, `describe()`
- **GroupBy**: Split-apply-combine with `groupBy()` → `sum()`, `mean()`, `count()`, `min()`, `max()`
- **Merge/Join**: SQL-style `merge(on:how:)` with inner, left, right, outer joins
- **Sorting**: `sortValues(by:ascending:)` on DataFrame and Series
- **Filtering**: Boolean mask filtering, `iloc()` positional access, `loc()` label access
- **NA handling**: `dropNA()`, `fillNA()`, `isNA()`, NA propagation in arithmetic
- **Reshaping**: `concat()`, `select(columns:)`, `drop(columns:)`, `rename(columns:)`
- **Value counts**: `valueCounts()` for frequency analysis
- **Arithmetic**: Element-wise `+`, `-`, `*`, `/` with NA propagation and scalar ops

### Performance
- Compiled C libraries (khash, skiplist, UltraJSON) via SPM C targets
- Apple Accelerate framework integration (vDSP) for vectorized math on macOS/iOS
- Copy-on-write value semantics via `isKnownUniquelyReferenced`
- Compact `BitVector` validity bitmaps (1 bit per element)

### Swift Idioms
- Value types (structs) with copy-on-write — no SettingWithCopyWarning
- `Sendable` conformance for Swift concurrency safety
- Protocol-oriented design (`PandasDType`, `PandasArray`, `PandasIndex`)
- Generic type system with concrete numeric dtypes

## Installation

Add SwiftPandas to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kiraa-ai/kiraa-swift-pandas.git", branch: "main"),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftPandas", package: "kiraa-swift-pandas"),
        ]
    ),
]
```

## Quick Start

```swift
import SwiftPandas

// Create a DataFrame
let df = DataFrame([
    "name_length": [5.0, 3.0, 7.0, 4.0],
    "age": [25.0, 30.0, 35.0, 28.0],
    "score": [88.0, 92.0, 75.0, 95.0],
])

// Basic operations
print(df.head())
print(df.describe())

// Column access returns a Series
let ages = df["age"]
print(ages.mean()!)  // 29.5

// Filtering
let mask = [true, false, true, false]
let filtered = df.filter(mask: mask)

// Sorting
let sorted = df.sortValues(by: "score", ascending: false)

// GroupBy
let grouped = DataFrame(columns: [
    ("dept", Column.fromStrings(["A", "B", "A", "B"])),
    ("salary", Column.fromDoubles([50.0, 60.0, 55.0, 65.0])),
])
let avgByDept = grouped.groupBy("dept").mean()

// Series with NAs
let s = Series([1.0, nil, 3.0, nil, 5.0], name: "values")
print(s.sum()!)    // 9.0
print(s.mean()!)   // 3.0
let filled = s.fillNA(0.0)

// Merge
let left = DataFrame(columns: [
    ("key", Column.fromStrings(["a", "b", "c"])),
    ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
])
let right = DataFrame(columns: [
    ("key", Column.fromStrings(["b", "c", "d"])),
    ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
])
let merged = left.merge(right, on: "key")

// Concat
let combined = DataFrame.concat([df, df])
```

## Project Structure

```
SwiftPandas/
├── Package.swift
├── Sources/
│   ├── CSkipList/           # C: skiplist for windowed median
│   ├── CKHash/              # C: klib hash tables
│   ├── CUltraJSON/          # C: UltraJSON encoder/decoder
│   └── SwiftPandas/
│       ├── Core/
│       │   ├── DType/       # Type system (DType protocol + concrete types)
│       │   ├── Array/       # Array types (NativeArray, NullableArray, StringArray, Column)
│       │   ├── Missing/     # BitVector validity bitmaps
│       │   └── Storage/     # CoW buffer management
│       ├── Index/           # Index types (RangeIndex, StringIndex, Int64Index)
│       ├── Series/          # Series type
│       ├── DataFrame/       # DataFrame type with GroupBy and Merge
│       └── Numeric/         # VectorOps with Accelerate support
└── Tests/
    └── SwiftPandasTests/    # 75 tests covering all components
```

## Roadmap

- [ ] CSV I/O (read/write)
- [ ] JSON I/O (bridging to CUltraJSON)
- [ ] Time series types (Timestamp, Timedelta, Period)
- [ ] Window functions (rolling, expanding, EWM) using CSkipList
- [ ] String operations (`.str` accessor)
- [ ] MultiIndex
- [ ] Additional I/O formats (Parquet, Excel)

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 16+

## License

This project is licensed under the BSD 3-Clause License, consistent with the original pandas project.

The vendored C libraries retain their original licenses:
- klib (khash): MIT License
- UltraJSON: BSD License
- Skiplist: BSD License

See the [pandas LICENSE](https://github.com/pandas-dev/pandas/blob/main/LICENSE) for the original project license.
