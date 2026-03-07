# SwiftPandas

A native Swift port of the [Python pandas](https://github.com/pandas-dev/pandas) data analysis library, targeting **macOS** with **Metal GPU acceleration** for compute-heavy operations.

SwiftPandas provides `DataFrame`, `Series`, and `Index` types for tabular data manipulation in Swift, with compiled C libraries (khash, skiplist, UltraJSON) for performance-critical operations, Apple Accelerate/vDSP for SIMD vectorization, and Metal compute shaders for GPU-accelerated GroupBy and Merge.

## Authors

- **Markos Abdallah**
- **Errol Brandt**

## Attribution

This project is a Swift port of [pandas](https://github.com/pandas-dev/pandas), the powerful Python data analysis library created by **Wes McKinney** and maintained by the [PyData Development Team](https://github.com/pandas-dev). The original pandas library is licensed under the [BSD 3-Clause License](https://github.com/pandas-dev/pandas/blob/main/LICENSE).

The following vendored C libraries from the pandas project are compiled directly as framework targets:

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
- Compiled C libraries (khash, skiplist, UltraJSON) compiled with `-O3`
- Apple Accelerate framework integration (vDSP) for vectorized math
- Copy-on-write value semantics via `isKnownUniquelyReferenced`
- Compact `BitVector` validity bitmaps (1 bit per element)
- FNV-1a open-addressing hash table for fast string factorization
- `UnsafeMutablePointer` accumulators in GroupBy fast paths (zero bounds-checking)
- **Metal GPU compute shaders** for GroupBy and Merge on Apple Silicon

### Swift Idioms
- Value types (structs) with copy-on-write — no SettingWithCopyWarning
- `Sendable` conformance for Swift concurrency safety
- Protocol-oriented design (`PandasDType`, `PandasArray`, `PandasIndex`)
- Generic type system with concrete numeric dtypes

## Installation

### Xcode Project (Recommended)

SwiftPandas is distributed as an Xcode project with precompiled Metal shaders. To build:

```bash
# Install xcodegen if needed
brew install xcodegen

# Generate Xcode project
xcodegen generate

# Build framework
xcodebuild build -scheme SwiftPandas -configuration Release

# Run tests
xcodebuild test -scheme SwiftPandas -configuration Release -destination 'platform=macOS'
```

To use in your own Xcode project, add the `SwiftPandas.framework` as a dependency.

### Swift Package Manager (Legacy)

SPM is supported for backward compatibility but does **not** include precompiled Metal shaders (shaders are compiled at runtime from embedded source strings):

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

> **Note**: SPM builds use `unsafeFlags(["-O3"])` for C libraries, which prevents distribution via SPM package registries. The Xcode project is the recommended distribution method.

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

## Project Structure

```
SwiftPandas/
├── project.yml                     # XcodeGen project spec
├── SwiftPandas.xcodeproj/          # Generated Xcode project
├── benchmark_pandas.py             # Python vs Swift side-by-side benchmark suite
├── Sources/
│   ├── CSkipList/                  # C: skiplist for windowed median (-O3)
│   ├── CKHash/                     # C: klib hash tables (-O3)
│   ├── CUltraJSON/                 # C: UltraJSON encoder/decoder (-O3)
│   └── SwiftPandas/
│       ├── Core/
│       │   ├── DType/              # Type system (DType protocol + concrete types)
│       │   ├── Array/              # Array types (NativeArray, NullableArray, StringArray, Column)
│       │   ├── Missing/            # BitVector validity bitmaps
│       │   └── Storage/            # CoW buffer management
│       ├── Index/                  # Index types (RangeIndex, StringIndex, Int64Index)
│       ├── Series/                 # Series type + arithmetic + comparison + apply
│       ├── DataFrame/              # DataFrame type with GroupBy, Merge, Concat
│       ├── Metal/                  # Metal GPU compute acceleration
│       │   ├── Shaders/
│       │   │   ├── ShaderCommon.h      # MurmurHash3, validity bitmap helpers
│       │   │   ├── GroupByShaders.metal # 5 GPU kernels: hash_insert, reduce_{sum,min,max,count}
│       │   │   └── MergeShaders.metal  # 2 GPU kernels: hash_build, hash_probe
│       │   ├── MetalContext.swift       # Singleton device/queue/library + pipeline cache
│       │   ├── MetalShaders.swift       # SPM-only: embedded MSL source strings
│       │   ├── MetalGroupBy.swift       # GPU GroupBy: factorize → hash → reduce
│       │   ├── MetalMerge.swift         # GPU Merge: co-factorize → hash build → probe
│       │   └── MetalDispatch.swift      # Threshold-based GPU/CPU routing (≥500K rows)
│       ├── IO/
│       │   └── CSV/                # CSV reader/writer with type inference
│       └── Numeric/                # VectorOps with Accelerate support
├── SwiftPandasApp/                 # macOS demo application (SwiftUI)
│   ├── SwiftPandasApp.swift        # @main entry point
│   ├── ContentView.swift           # TabView with 3 demo tabs
│   └── DemoViews/
│       ├── DataFrameDemoView.swift # DataFrame creation, filter, sort, aggregate
│       ├── GroupByDemoView.swift   # GroupBy sum/mean/count/min/max
│       └── BenchmarkView.swift     # CPU vs GPU benchmark with configurable size
├── Tests/
│   └── SwiftPandasTests/           # 163 tests covering all components
│       ├── CSVDataFrameTests.swift     # Comprehensive API documentation tests
│       ├── BenchmarkTests.swift        # Performance benchmarks (Swift vs Python pandas)
│       ├── MetalTests.swift            # GPU correctness tests (GroupBy, Merge, dispatch)
│       ├── NewFeaturesTests.swift      # Comparison, apply, groupby, concat tests
│       └── SampleData/employees.csv    # 15-row sample dataset
└── Package.swift                   # SPM manifest (legacy/backward compatibility)
```

## Xcode Project Targets

| Target | Type | Description |
|---|---|---|
| **SwiftPandas** | macOS Framework | Core library with Metal shaders precompiled to `default.metallib` |
| **SwiftPandasApp** | macOS Application | SwiftUI demo app with DataFrame, GroupBy, and Benchmark views |
| **SwiftPandasTests** | Unit Test Bundle | 163 tests including GPU correctness and performance benchmarks |

The project is generated via [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. Build settings:

- **Swift**: `-O` optimization in Release
- **C libraries**: `-O3` in all configurations
- **Metal**: Precompiled `.metal` → `default.metallib` at build time
- **Framework**: `ENABLE_TESTABILITY = YES` in Release for benchmark validation
- **Deployment target**: macOS 13.0

## Metal GPU Acceleration

SwiftPandas uses Metal compute shaders to accelerate GroupBy and Merge operations on Apple Silicon. GPU dispatch is transparent — operations automatically use the GPU for datasets ≥ 500K rows and fall back to the CPU for smaller datasets.

### Architecture

```
CPU (Swift)                          GPU (Metal Compute Shaders)
─────────────                        ─────────────────────────────
1. Factorize string/numeric keys
   → integer codes (FNV-1a hash)
                                     2. groupby_hash_insert kernel
2. Upload codes to GPU buffer           Open-addressing hash table
   (unified memory, zero-copy)          Atomic CAS for thread safety
                                        Maps codes → group IDs

                                     3. groupby_reduce_{sum,min,max,count}
                                        Per-thread atomic accumulation
                                        BitVector validity checks

4. Read back results from GPU
   Build result DataFrame
```

### Metal Shader Details

**7 GPU Compute Kernels** in 2 shader files:

#### GroupBy Shaders (`GroupByShaders.metal`)
- **`groupby_hash_insert`** — Open-addressing hash table maps factorized key codes to group IDs. Uses `atomic_compare_exchange_weak` for thread-safe slot insertion. Spin-waits on group ID write for concurrent readers.
- **`groupby_reduce_sum`** — Parallel reduction with `atomic_fetch_add` on Float accumulators. Checks BitVector validity bitmaps to skip NA values.
- **`groupby_reduce_min`** / **`groupby_reduce_max`** — Atomic compare-exchange loops for min/max. Initializes accumulators to `±Float.greatestFiniteMagnitude`.
- **`groupby_reduce_count`** — Atomic increment of per-group counters with validity checking.

#### Merge Shaders (`MergeShaders.metal`)
- **`merge_hash_build`** — Builds hash table from right table's factorized key codes. Duplicate keys are chained via `chain_next` linked list using `atomic_exchange`.
- **`merge_hash_probe`** — Each left-table thread probes the hash table. Follows `chain_next` chains for duplicate matches. Output pairs are written to global buffers via `atomic_fetch_add` on an output counter.

#### Shared Utilities (`ShaderCommon.h`)
- **`hash_uint`** / **`hash_int32`** — MurmurHash3-style finalizer for integer hashing
- **`hash_combine`** — Hash combiner using the golden ratio constant (`0x9e3779b9`)
- **`is_valid`** — BitVector validity check (packed `[UInt64]` → `[UInt32]` pairs on GPU)
- **`EMPTY_SLOT`** — Sentinel value (`-1`) for empty hash table slots

### GPU Dispatch Logic

```swift
public enum MetalDispatch {
    public static var groupByThreshold = 500_000
    public static var mergeThreshold   = 500_000

    public static var isAvailable: Bool {
        MetalContext.shared != nil
    }
}
```

- **Threshold-based**: CPU fast-path beats GPU for < 500K rows due to dispatch overhead
- **Automatic fallback**: Returns `nil` if GPU fails → caller uses CPU path
- **Unified memory**: Apple Silicon shares memory between CPU and GPU — near zero-copy buffer transfers
- **Pipeline caching**: All 7 compute pipeline states are created once at `MetalContext` initialization

### Xcode vs SPM Shader Loading

| Build System | Shader Loading | Performance |
|---|---|---|
| **Xcode** | `.metal` files precompiled to `default.metallib` at build time | Instant load |
| **SPM** | MSL source strings compiled at runtime via `device.makeLibrary(source:)` | ~100ms first-call overhead |

## Test Suite

163 tests across all components:

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
| Metal GPU | 16 | GPU GroupBy (sum/mean/count/min/max), GPU Merge, dispatch |
| Integration | 1 | End-to-end pandas-style workflow |
| VectorOps | 4 | Accelerate/scalar math operations |
| Benchmarks | 14 | Performance comparison vs Python pandas |
| Other | 10 | Version, column, format, edge cases |

## Performance: SwiftPandas vs Python pandas

Both Swift and Python benchmarks are compiled with full optimizations:
- **Swift**: `-O` (Release configuration), C libraries with `-O3`
- **Python**: pandas with C/Cython extensions, NumPy with SIMD/vDSP

Run benchmarks:
```bash
# Swift benchmarks (Release optimized)
xcodebuild test -scheme SwiftPandas -configuration Release -destination 'platform=macOS' \
    -only-testing:SwiftPandasTests/BenchmarkTests

# Full side-by-side comparison (Python + Swift)
python3 benchmark_pandas.py
```

All benchmarks at **1M rows** (merge at 100K). Best of 3 runs.

### Benchmark Results

| Operation | SwiftPandas | Python pandas | Winner | vs Python |
|---|---|---|---|---|
| **Aggregation** | | | | |
| sum() 1M | 93 µs | 213 µs | **Swift** | +56% faster |
| mean() 1M | 88 µs | 778 µs | **Swift** | +89% faster |
| std() 1M | 558 µs | 2,255 µs | **Swift** | +75% faster |
| min() 1M | 83 µs | 687 µs | **Swift** | +88% faster |
| max() 1M | 87 µs | 680 µs | **Swift** | +87% faster |
| median() 1M | 7,009 µs | 8,107 µs | **Swift** | +14% faster |
| quantile() 1M | 4,313 µs | 9,272 µs | **Swift** | +53% faster |
| **Arithmetic** | | | | |
| Series + Series 1M | 248 µs | 200 µs | Tie | -24% |
| Series * scalar 1M | 177 µs | 134 µs | Tie | -32% |
| **DataFrame** | | | | |
| construct 1M | 15 ms | 10,252 ms | **Swift** | +99% faster |
| filter 1M (6 cols) | 16 ms | 1.8 ms | pandas | -789% slower |
| sum() 1M (6 cols) | 643 µs | 1,483 µs | **Swift** | +57% faster |
| mean() 1M (6 cols) | 653 µs | 4,646 µs | **Swift** | +86% faster |
| std() 1M (6 cols) | 3,369 µs | 10,963 µs | **Swift** | +69% faster |
| **GroupBy** | | | | |
| sum (100 groups) | 9 ms | 2.3 ms | pandas | -291% slower |
| sum (10K groups) | 46 ms | 6.6 ms | pandas | -597% slower |
| **Merge** | | | | |
| inner 100K | 18 ms | 13 ms | pandas | -38% slower |
| **Concat** | | | | |
| 10 x 100K | 4.9 ms | 0.8 ms | pandas | -513% slower |
| **CSV I/O** | | | | |
| read 1M | 921 ms | 142 ms | pandas | -549% slower |
| write 1M | 9,115 ms | 1,644 ms | pandas | -454% slower |

### Summary by Category

| Category | Winner | Why |
|---|---|---|
| **Aggregation (sum/mean/std/min/max)** | **Swift** | Accelerate vDSP SIMD (2-9x faster) |
| **DataFrame Aggregation** | **Swift** | Accelerate vDSP per-column (2-7x faster) |
| **DataFrame Construction** | **Swift** | Direct ContiguousArray alloc, no BlockManager (686x) |
| **Median/Quantile** | **Swift** | O(n) quickselect (1.2-2.1x faster) |
| Series Arithmetic | Tie | Both use SIMD, comparable throughput |
| Merge/Join | pandas | C-level hash join (1.3x) |
| Boolean Filtering | pandas | NumPy fancy indexing in C (9x) |
| GroupBy | pandas | Cython hash tables (3-7x) |
| Sorting | pandas | NumPy introsort/radixsort in C (1.5-5x) |
| CSV I/O | pandas | C tokenizer vs Swift byte-level parser (5-7x) |

### Optimizations Applied

- **Accelerate/vDSP**: Vectorized aggregation and arithmetic wired into NullableArray + NativeArray
- **FNV-1a hash factorization**: Custom open-addressing hash table with `UnsafeMutablePointer<Int32>` slots replaces Swift Dictionary (2x faster for string factorization)
- **UnsafeMutablePointer accumulators**: GroupBy fast paths use raw pointers to eliminate bounds checking in hot loops
- **O(n) quickselect**: For median/quantile with raw pointer inner loop
- **Byte-level CSV parser**: UTF-8 state machine, avoids `Array(text)` character copy
- **Typed merge**: Direct Double/String hash, not `formattedValue` → String
- **Optimized filter**: Single mask scan → index gather, raw pointer take operations
- **Compiler flags**: `-O` Swift, `-O3` for vendored C libraries

*Benchmarked on Apple M2 Max, 32GB RAM, macOS 14, Swift 5.9 Release, Python 3.11, pandas 2.2, NumPy 1.26*

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
- [x] Performance benchmarks (Swift vs Python pandas)
- [x] Metal GPU compute shaders for GroupBy and Merge (7 kernels)
- [x] Precompiled Metal shaders via Xcode (`.metal` → `default.metallib`)
- [x] Python vs Swift side-by-side benchmark suite (`benchmark_pandas.py`)
- [x] Wire VectorOps/Accelerate into NullableArray arithmetic
- [x] O(n) quickselect for median/quantile
- [x] Byte-level CSV parser
- [x] FNV-1a hash factorization with open-addressing table
- [x] UnsafeMutablePointer accumulators for GroupBy
- [x] Typed merge (Double/String hash, not String formatting)
- [x] Optimized filter pipeline (single mask scan, raw pointer gather)
- [x] Compiler optimization flags (-O Swift, -O3 C)
- [x] Xcode project with XcodeGen (Framework + App + Tests)
- [x] macOS demo app (SwiftUI) with DataFrame, GroupBy, and Benchmark views
- [ ] JSON I/O (bridging to CUltraJSON)
- [ ] Time series types (Timestamp, Timedelta, Period)
- [ ] Window functions (rolling, expanding, EWM) using CSkipList
- [ ] String operations (`.str` accessor)
- [ ] MultiIndex
- [ ] Additional I/O formats (Parquet, Excel)

## Requirements

- Swift 5.9+
- macOS 13+
- Xcode 15+ (for Metal shader compilation)
- Apple Silicon or discrete GPU (for Metal acceleration)

## License

This project is licensed under the BSD 3-Clause License, consistent with the original pandas project.

The vendored C libraries retain their original licenses:
- klib (khash): MIT License
- UltraJSON: BSD License
- Skiplist: BSD License

See the [pandas LICENSE](https://github.com/pandas-dev/pandas/blob/main/LICENSE) for the original project license.
