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
- **`DataFrame`** — 2D labeled tabular data with column-oriented storage and box-drawing table display
- **`Series`** — 1D labeled array with numeric, string, and boolean support
- **`Index`** — Label-based axis indexing (`RangeIndex`, `StringIndex`, `Int64Index`)

### Data Types
- All numeric columns default to `Double` for type consistency
- `NullableArray<T>` with `BitVector` validity bitmaps for NA support
- `NativeArray<T>` with copy-on-write semantics
- `StringArray` for string data with NA handling
- `Column` enum for type-erased heterogeneous DataFrame columns (`.double`, `.string`, `.bool`, `.int64`)
- Full DType hierarchy: `Int8`–`Int64`, `UInt8`–`UInt64`, `Float32`, `Float64`, `Bool`, `String`

### Series Operations
- **Aggregations**: `sum()`, `mean()`, `std()`, `min()`, `max()`, `median()`, `quantile()`, `describe()`, `valueCounts()`
- **Arithmetic**: Element-wise `+`, `-`, `*`, `/` between Series and with scalars
- **Comparison**: `>`, `>=`, `<`, `<=` returning `[Bool]` masks; `eq()`, `ne()` for Double and String; `strContains()`
- **Apply & Map**: `apply { $0 * 2 }` for transforms, `map(dict)` for remapping (Double and String)
- **Cumulative**: `cumsum()`
- **Unique & Duplicates**: `unique()`, `nUnique`, `duplicated()`, `dropDuplicates()`
- **NA handling**: `dropNA()`, `fillNA()`, `isNA()`, NA propagation in arithmetic
- **Sorting**: `sortValues(ascending:)`
- **Indexing**: `s[i]`, `iloc()`, `loc()`, `head()`, `tail()`

### DataFrame Operations
- **Column access**: `df["col"]` (get/set), `select(columns:)`, `drop(columns:)`, `rename(columns:)`
- **Row access**: `iloc()` positional, `loc()` label-based, `head()`, `tail()`
- **Boolean filtering**: `df[df["age"] > 30]` pandas-style syntax, `filter(mask:)`
- **Sorting**: `sortValues(by:ascending:)` single and multi-column with NA handling
- **Aggregations**: `sum()`, `mean()`, `std()`, `min()`, `max()`, `median()`, `describe()` with quartiles
- **Duplicates**: `duplicated(subset:)`, `dropDuplicates(subset:)`
- **Apply**: `apply { series in ... }` per-column transform
- **GroupBy**: `groupBy("col")` and `groupBy(["col1","col2"])` with `sum()`, `mean()`, `count()`, `min()`, `max()`
- **Merge/Join**: SQL-style `merge(on:how:)` with `.inner`, `.left`, `.right`, `.outer`
- **Concat**: `DataFrame.concat([df1, df2])` vertical stacking with mixed column types

### CSV I/O
- **Read**: `DataFrame.readCSV(string)`, `DataFrame.readCSV(path:)` with auto type inference
- **Write**: `df.toCSV()`, `df.toCSV(path:)` with configurable separator, header, index
- **Custom parsing**: `CSVReader(separator:header:naValues:)` — handles quoted fields, escaped quotes, mixed line endings
- **NA values**: `""`, `"NA"`, `"N/A"`, `"NaN"`, `"null"`, `"NULL"`, `"None"`, `"."`

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

// Load CSV data
let df = DataFrame.readCSV("""
name,department,salary,age
Alice,Engineering,95000,32
Bob,Marketing,72000,28
Charlie,Engineering,105000,35
Diana,Sales,68000,26
Eve,Engineering,115000,40
""")

print(df)
// ┌───┬─────────┬─────────────┬────────┬─────┐
// │   │ name    │ department  │ salary │ age │
// ├───┼─────────┼─────────────┼────────┼─────┤
// │ 0 │ Alice   │ Engineering │  95000 │  32 │
// │ 1 │ Bob     │ Marketing   │  72000 │  28 │
// │ 2 │ Charlie │ Engineering │ 105000 │  35 │
// │ 3 │ Diana   │ Sales       │  68000 │  26 │
// │ 4 │ Eve     │ Engineering │ 115000 │  40 │
// └───┴─────────┴─────────────┴────────┴─────┘

// Summary statistics with quartiles
print(df.describe())

// Column access returns a Series
let salaries = df["salary"]
print(salaries.mean()!)  // 91000.0

// Pandas-style boolean filtering
let highEarners = df[df["salary"] > 90000.0]

// Sort by salary descending
let sorted = df.sortValues(by: "salary", ascending: false)

// GroupBy with aggregation
let avgByDept = df.select(columns: ["department", "salary"])
    .groupBy("department").mean()

// Apply transforms
let normalized = (df["salary"] - df["salary"].mean()!) / df["salary"].std()!

// Series with NAs
let s = Series([1.0, nil, 3.0, nil, 5.0], name: "values")
print(s.sum()!)    // 9.0
print(s.mean()!)   // 3.0
let filled = s.fillNA(0.0)

// Merge two DataFrames
let departments = DataFrame(columns: [
    ("department", Column.fromStrings(["Engineering", "Marketing", "Sales"])),
    ("budget", Column.fromDoubles([500000, 300000, 250000])),
])
let withBudget = df.merge(departments, on: "department")

// Concat vertically
let combined = DataFrame.concat([df.head(3), df.tail(2)])

// CSV round-trip
let csvString = df.toCSV()
try df.toCSV(path: "/path/to/output.csv")
```

## API Reference

Run `./run_csv_demo.sh` to see a comprehensive, live API reference with examples covering all features:

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                      SWIFTPANDAS 0.1.0 — API REFERENCE                       ║
╚══════════════════════════════════════════════════════════════════════════════╝

  1. Series — 1D Labeled Array
     Construction          Series([Double]), Series(dict), ...
     Properties            count, dtype, isNumeric, name, index
     Indexing              s[i], iloc, loc, head, tail
     NA Handling           isNA, dropNA, fillNA
     Aggregations          sum, mean, std, min, max, median, quantile
     ...

  2. DataFrame — 2D Labeled Table
  3. GroupBy — Split-Apply-Combine
  4. Merge & Concat — Combining DataFrames
  5. CSV I/O — Read & Write
  6. Core Types — Storage & Type System
  7. Index Types — Label Management
  8. End-to-End Pipeline Demo
```

## Project Structure

```
SwiftPandas/
├── Package.swift
├── run_csv_demo.sh              # API reference & test runner
├── Sources/
│   ├── CSkipList/               # C: skiplist for windowed median
│   ├── CKHash/                  # C: klib hash tables
│   ├── CUltraJSON/              # C: UltraJSON encoder/decoder
│   └── SwiftPandas/
│       ├── Core/
│       │   ├── DType/           # Type system (DType protocol + concrete types)
│       │   ├── Array/           # Array types (NativeArray, NullableArray, StringArray, Column)
│       │   ├── Missing/         # BitVector validity bitmaps
│       │   └── Storage/         # CoW buffer management
│       ├── Index/               # Index types (RangeIndex, StringIndex, Int64Index)
│       ├── Series/              # Series type + arithmetic + comparison + apply
│       ├── DataFrame/           # DataFrame type with GroupBy, Merge, Concat
│       ├── IO/
│       │   └── CSV/             # CSV reader/writer with type inference
│       └── Numeric/             # VectorOps with Accelerate support
└── Tests/
    └── SwiftPandasTests/        # 133 tests covering all components
        ├── CSVDataFrameTests.swift    # Comprehensive API documentation tests
        ├── NewFeaturesTests.swift     # Comparison, apply, groupby, concat tests
        └── SampleData/employees.csv   # 15-row sample dataset
```

## Test Suite

133 tests across all components:

| Category | Tests | Coverage |
|---|---|---|
| BitVector | 8 | Bitmap operations, bitwise AND/OR/NOT |
| NativeArray | 9 | CoW, arithmetic, sorting, unique |
| NullableArray | 9 | NA handling, aggregations, factorize |
| StringArray | 5 | String storage, NA, unique, sort |
| Index Types | 7 | RangeIndex, StringIndex, Int64Index |
| DType | 2 | Type system validation |
| Series | 11 | Construction, aggregation, describe |
| DataFrame | 15 | Construction, access, filter, sort, merge |
| CSV I/O | 10 | Read, write, round-trip, file I/O, documentation |
| Comparisons | 11 | >, >=, <, <=, eq, ne, strContains |
| Apply & Map | 4 | apply, map (Double & String) |
| Scalar Arithmetic | 3 | +, -, *, / with scalars |
| Statistics | 7 | median, quantile, cumsum |
| Duplicates | 7 | unique, duplicated, dropDuplicates |
| Loc/iloc | 3 | Label-based row access |
| Boolean Mask | 2 | df[mask] subscript |
| Multi-Column Sort | 2 | Multi-key sorting |
| Multi-Column GroupBy | 2 | Composite key groupby |
| Concat | 2 | Vertical stacking with mixed types |
| Integration | 1 | End-to-end pandas-style workflow |
| VectorOps | 4 | Accelerate/scalar math operations |
| Other | 10 | Version, column, format, edge cases |

## Roadmap

- [x] CSV I/O (read/write)
- [x] Comparison operators (>, >=, <, <=, eq, ne)
- [x] Apply/Map transforms
- [x] Median, quantile, cumulative sum
- [x] Multi-column sort and groupby
- [x] Unique/duplicated/dropDuplicates
- [x] Label-based indexing (loc)
- [x] Boolean mask subscript (`df[mask]`)
- [x] Concat with mixed column types
- [x] Pretty-printed table output with box drawing
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
