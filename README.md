<p align="center">
  <img src="swift_pandas.png" alt="SwiftPandas" width="400">
</p>

# SwiftPandas v0.4.0-beta

> **BETA RELEASE** — This library is under active development and testing. APIs may change between releases. We welcome bug reports and feedback via [GitHub Issues](https://github.com/kiraa-ai/kiraa-swift-pandas/issues).

A native Swift port of the [Python pandas](https://github.com/pandas-dev/pandas) data analysis library, targeting **macOS** with **Metal GPU acceleration** for compute-heavy operations and a **Polars-style lazy evaluation engine** with query optimization.

SwiftPandas provides `DataFrame`, `Series`, and `Index` types for tabular data manipulation in Swift, with compiled C libraries (khash, skiplist, UltraJSON) for performance-critical operations, Apple Accelerate/vDSP for SIMD vectorization, Metal compute shaders for GPU-accelerated GroupBy and Merge, and a lazy evaluation engine with filter fusion, predicate pushdown, and projection pushdown.

## Status

This library is in **beta**. The core API is stabilizing but may still change. We are actively:
- Expanding test coverage across all subsystems
- Profiling and optimizing performance bottlenecks
- Validating correctness against Python pandas on real-world datasets
- Documenting all public APIs with comprehensive Swift doc comments

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
- **Optimized reader**: Flat field grid (no 2D array overhead), custom fast double parser, reusable strtod buffer, switch-based NA matching

### Lazy Evaluation & Query Optimization
- **`LazyDataFrame`** — builds a query plan instead of materializing intermediate DataFrames
- **`df.lazy()`** → chain `.filter()`, `.select()`, `.groupBy().sum()` → `.collect()`
- **Inspectable predicates**: `col("revenue") > 1000`, `col("name").contains("Inc")`, combinators `&`, `|`, `!`
- **Query optimizer** with 4 optimization passes:
  - **Filter fusion**: consecutive filters merged into single `AND` predicate
  - **Predicate pushdown**: filters moved below sort/groupBy/select/join
  - **Projection pushdown**: unused columns eliminated early
  - **Redundant elimination**: identity selects removed, limits combined
- **`explain()`** / **`explainRaw()`** — inspect optimized and raw query plans
- **`LazyGroupBy`** — deferred `sum()`, `mean()`, `count()`, `min()`, `max()`
- **Merge support**: `lazy.merge(otherLazy, on: "key", how: .inner)`

### Performance
- Compiled C libraries (khash, skiplist, UltraJSON) compiled with `-O3`
- Apple Accelerate framework integration (vDSP) for vectorized math and arithmetic
- Copy-on-write value semantics via `isKnownUniquelyReferenced`
- Compact `BitVector` validity bitmaps (1 bit per element)
- FNV-1a open-addressing hash table for fast string factorization
- `UnsafeMutablePointer` accumulators in GroupBy fast paths (zero bounds-checking)
- **Metal GPU compute shaders** for GroupBy and Merge on Apple Silicon
- **Lazy evaluation engine** with query optimizer (filter fusion, predicate/projection pushdown)
- **Optimized CSV reader**: flat field grid, custom `fastParseDouble`, reusable strtod buffer, switch-based NA matching

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

// Lazy evaluation — no intermediate DataFrames
let result = df.lazy()
    .filter(col("salary") > 80000)
    .select("name", "department", "salary")
    .groupBy("department").mean()
    .collect()

// Inspect the optimized query plan
print(df.lazy()
    .filter(col("salary") > 80000)
    .select("name", "department", "salary")
    .groupBy("department").mean()
    .explain())

// CSV round-trip
let csvString = df.toCSV()
try df.toCSV(path: "/path/to/output.csv")
```

## Project Structure

```
SwiftPandas/
├── project.yml                     # XcodeGen project spec
├── SwiftPandas.xcodeproj/          # Generated Xcode project
├── benchmarks/
│   ├── benchmark_pandas.py         # Python vs Swift side-by-side benchmark suite
│   ├── run_all.py                  # Run all 30 individual benchmarks
│   └── tests/                      # 30 individual benchmark scripts (01-30)
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
│       ├── Lazy/                   # Lazy evaluation & query optimization
│       │   ├── Predicate.swift         # Col, ColumnPredicate expression tree + operators
│       │   ├── QueryPlan.swift         # Logical query plan (indirect enum)
│       │   ├── LazyDataFrame.swift     # LazyDataFrame API + LazyGroupBy
│       │   ├── QueryOptimizer.swift    # 4-pass optimizer (fusion, pushdown, elimination)
│       │   └── QueryExecutor.swift     # Recursive plan execution via eager DataFrame ops
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
│   └── SwiftPandasTests/           # 206 tests covering all components
│       ├── SwiftPandasTests.swift      # Core unit tests (types, Series, DataFrame, GroupBy, Merge)
│       ├── CSVDataFrameTests.swift     # Comprehensive API documentation & demo tests
│       ├── BenchmarkTests.swift        # Performance benchmarks (Swift vs Python pandas)
│       ├── LazyDataFrameTests.swift    # Lazy evaluation, predicates, optimizer tests
│       ├── MetalTests.swift            # GPU correctness tests (GroupBy, Merge, dispatch)
│       └── SampleData/employees.csv    # 15-row sample dataset
└── Package.swift                   # SPM manifest (legacy/backward compatibility)
```

## Xcode Project Targets

| Target | Type | Description |
|---|---|---|
| **SwiftPandas** | macOS Framework | Core library with Metal shaders precompiled to `default.metallib` |
| **SwiftPandasApp** | macOS Application | SwiftUI demo app with DataFrame, GroupBy, and Benchmark views |
| **SwiftPandasTests** | Unit Test Bundle | 206 tests including GPU correctness, lazy evaluation, and performance benchmarks |

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
    public static var groupByThreshold = 10_000_000
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

## Testing

### Running Tests

208 tests across 5 test files. All tests use XCTest.

```bash
# Run all tests (Debug, via Swift Package Manager)
swift test

# Run all tests (Release optimized, via Xcode — recommended)
xcodebuild test -scheme SwiftPandas -configuration Release \
    -destination 'platform=macOS'

# Run a specific test file
swift test --filter SwiftPandasTests       # core unit tests
swift test --filter CSVDataFrameTests      # CSV & API demos
swift test --filter LazyDataFrameTests     # lazy evaluation engine
swift test --filter MetalTests             # GPU compute shaders
swift test --filter BenchmarkTests         # performance benchmarks
```

> **Note:** `swift test` runs in Debug mode by default. Use the `xcodebuild`
> command with `-configuration Release` for accurate benchmark timings, as
> Swift's `-O` optimization flag makes a significant difference for numeric code.

### Test Files

| File | Tests | Coverage |
|---|---|---|
| **SwiftPandasTests.swift** | ~90 | Core types (DType, NativeArray, BitVector, NullableArray, StringArray, Column, Index), Series (construction, aggregation, statistics, NA handling, arithmetic, comparison, apply/map, cumsum, unique/duplicated, sorting), DataFrame (construction, column access, row access, loc, filtering, mask subscript, single/multi-column sorting, aggregation, describe, duplicates, concat, rename), GroupBy (single/multi-column), Merge (inner, left), integration workflow |
| **CSVDataFrameTests.swift** | ~10 | API documentation demos covering Series, DataFrame, GroupBy, Merge, Concat, CSV I/O, Core Types, Index Types, full pipeline; CSV file round-trip |
| **LazyDataFrameTests.swift** | ~44 | Predicates (comparison, string, AND/OR/NOT), LazyDataFrame ops (filter, select, drop, sort, head, groupBy, merge), chained operations, query optimizer (filter fusion, predicate pushdown, limit elimination, identity select removal), explain output, edge cases (empty, single-row, all-filtered, NA values) |
| **MetalTests.swift** | ~16 | Metal dispatch threshold logic, GPU GroupBy correctness (sum/mean/count/min/max, large dataset 100K), GPU Merge (inner join, no-matches, duplicate keys, column naming), GPU/CPU integration |
| **BenchmarkTests.swift** | ~15 | Performance benchmarks at 1M rows: Series aggregation/arithmetic/sorting/statistics, DataFrame construction/filtering/sorting/aggregation, GroupBy, Merge, Concat, CSV I/O, Lazy vs Eager |

### Python Benchmarks

30 individual Python benchmark scripts provide detailed, per-operation analysis
with configurable parameters, correctness checks, throughput analysis, and
scaling comparisons. Requires `pandas` and `numpy`.

```bash
# Install Python dependencies
pip install pandas numpy

# Full side-by-side comparison (Python pandas + SwiftPandas via xcodebuild)
python3 benchmarks/benchmark_pandas.py

# List all 30 individual benchmarks
python3 benchmarks/run_all.py --list

# Run all 30 individual benchmarks sequentially
python3 benchmarks/run_all.py

# Run specific benchmarks by number
python3 benchmarks/run_all.py 1 6 29

# Run a single benchmark with custom parameters
python3 benchmarks/tests/01_series_sum.py                    # defaults: 1M rows, 5 iters
python3 benchmarks/tests/01_series_sum.py -n 5000000 -i 10   # 5M rows, 10 iterations
python3 benchmarks/tests/27_merge_inner.py -n 200000 -w 3    # 200K rows, 3 warmup rounds
```

Each individual benchmark script accepts these flags:

| Flag | Default | Description |
|---|---|---|
| `-n`, `--rows` | 1,000,000 | Number of rows (100,000 for merge/concat) |
| `-i`, `--iterations` | 5 | Number of timed iterations |
| `-w`, `--warmup` | 1 | Number of warmup iterations (not timed) |
| `--seed` | 42 | LCG seed for deterministic data generation |

The 30 benchmarks cover every operation measured in the Swift benchmark suite:

| # | Script | Operation |
|---|---|---|
| 1-6 | `01_series_sum.py` — `06_series_median.py` | Series aggregations (sum, mean, std, min, max, median) |
| 7-10 | `07_series_add.py` — `10_series_multiply_scalar.py` | Series arithmetic (element-wise and scalar) |
| 11-14 | `11_series_sort.py` — `14_series_value_counts.py` | Series sort, quantile, cumsum, valueCounts |
| 15-22 | `15_dataframe_construct.py` — `22_dataframe_describe.py` | DataFrame construction, filter, sort, aggregation, describe |
| 23-26 | `23_groupby_sum_100g.py` — `26_groupby_sum_10k.py` | GroupBy sum/mean/count at 100 and 10K groups |
| 27 | `27_merge_inner.py` | Inner join (merge) at 100K rows |
| 28 | `28_concat.py` | Vertical concatenation (10 x 100K) |
| 29-30 | `29_csv_read.py` — `30_csv_write.py` | CSV read and write at 1M x 6 |

## Performance: SwiftPandas vs Python pandas

Both Swift and Python benchmarks are compiled with full optimizations:
- **Swift**: `-O` (Release configuration), C libraries with `-O3`
- **Python**: pandas with C/Cython extensions, NumPy with SIMD/vDSP

### Benchmark Results

**Scorecard: Swift wins 22 | pandas wins 8** (30 benchmarks)
**Overall: SwiftPandas is 21.2% faster than pandas on average**

| Operation | SwiftPandas | Python pandas | Winner | vs Python |
|---|---|---|---|---|
| **Aggregation** | | | | |
| sum() 1M | 83 µs | 216 µs | **Swift** | +62% faster |
| mean() 1M | 85 µs | 732 µs | **Swift** | +88% faster |
| std() 1M | 524 µs | 2,320 µs | **Swift** | +77% faster |
| min() 1M | 79 µs | 689 µs | **Swift** | +89% faster |
| max() 1M | 81 µs | 700 µs | **Swift** | +88% faster |
| median() 1M | 6,797 µs | 8,281 µs | **Swift** | +18% faster |
| quantile() 1M | 4,356 µs | 9,377 µs | **Swift** | +54% faster |
| **Arithmetic** | | | | |
| Series + Series 1M | 212 µs | 226 µs | **Swift** | +6% faster |
| Series * Series 1M | 208 µs | 219 µs | **Swift** | +5% faster |
| Series + scalar 1M | 156 µs | 147 µs | pandas | -6% slower |
| Series * scalar 1M | 151 µs | 147 µs | pandas | -3% slower |
| **Series Stats** | | | | |
| cumsum() 1M | 567 µs | 2,410 µs | **Swift** | +76% faster |
| **DataFrame** | | | | |
| construct 1M | 6.4 ms | 10,128 ms | **Swift** | 1583x faster |
| filter 1M (6 cols) | 5.4 ms | 1.8 ms | pandas | -197% slower |
| sum() 1M (6 cols) | 554 µs | 1,433 µs | **Swift** | +61% faster |
| mean() 1M (6 cols) | 565 µs | 2,375 µs | **Swift** | +76% faster |
| std() 1M (6 cols) | 3,385 µs | 8,737 µs | **Swift** | +61% faster |
| **GroupBy** | | | | |
| sum (100 groups) | 816 µs | 2,284 µs | **Swift** | +64% faster |
| mean (100 groups) | 1,037 µs | 2,428 µs | **Swift** | +57% faster |
| count (100 groups) | 561 µs | 1,093 µs | **Swift** | +49% faster |
| sum (10K groups) | 872 µs | 6,485 µs | **Swift** | +87% faster |
| **Merge** | | | | |
| inner 100K | 12.7 ms | 13.2 ms | **Swift** | +3% faster |
| **Concat** | | | | |
| 10 x 100K | 1.2 ms | 0.8 ms | pandas | -61% slower |
| **CSV I/O** | | | | |
| read 1M | 124 ms | 142 ms | **Swift** | +13% faster |
| write 1M | 340 ms | 1,627 ms | **Swift** | +79% faster |
| **Lazy Evaluation** | | | | |
| multi-filter chain 1M | 8.8 ms (lazy) | 12.6 ms (eager) | **Lazy** | 1.4x faster |

### Summary by Category

| Category | Winner | Why |
|---|---|---|
| **Aggregation (sum/mean/std/min/max)** | **Swift** | Accelerate vDSP SIMD (2-9x faster) |
| **DataFrame Aggregation** | **Swift** | Accelerate vDSP per-column (2.5-8x faster) |
| **DataFrame Construction** | **Swift** | Lazy index + direct ContiguousArray alloc (1583x) |
| **GroupBy** | **Swift** | Cached factorize + FNV-1a hash precheck + tight accumulate (1.5-7.4x faster) |
| **Median/Quantile** | **Swift** | O(n) quickselect (1.2-2.1x faster) |
| **Cumsum** | **Swift** | Raw pointer prefix sum + lazy index (4.3x faster) |
| **CSV I/O** | **Swift** | Custom fast double parser, flat field grid (read 1.1x, write 4.8x faster) |
| **Series Arithmetic** | **Swift** | vDSP/SIMD + lazy index (no string allocation overhead) |
| **Merge/Join** | **Swift** | Typed hash join with pre-allocated buffers (+3%) |
| Boolean Filtering | pandas | NumPy fancy indexing in C (3x) |
| Sorting | pandas | NumPy introsort/radixsort in C |

### Optimizations Applied

- **Lazy index labels**: `DataFrame` and `Series` use lazy-evaluated index labels — default range indices (`0, 1, 2, ...`) are never materialized as strings unless accessed for display or label-based lookup. Eliminates millions of string allocations in arithmetic, filter, cumsum, concat, and construction.
- **Accelerate/vDSP**: Vectorized aggregation and arithmetic wired into NullableArray + NativeArray
- **FNV-1a hash factorization**: Custom open-addressing hash table with `UnsafeMutablePointer<Int32>` slots, hash-value caching for O(1) resize, hash precheck before string comparison on collision, and `withContiguousStorageIfAvailable` for raw UTF-8 pointer hashing
- **Cached factorize on GroupBy**: Group codes computed once at `groupBy()` creation, reused across all `.sum()`, `.mean()`, `.count()` calls. Two-pass architecture (factorize → tight accumulate loop) gives better cache utilization than fused single-pass.
- **UnsafeMutablePointer accumulators**: GroupBy accumulation uses raw pointers for zero bounds-checking in the hot `for i in 0..<n { sums[codes[i]] += data[i] }` loop
- **Adaptive GPU/CPU dispatch**: Metal GPU reserved for >10M rows; CPU fast-path with raw pointer accumulation beats GPU atomics for typical group counts
- **O(n) quickselect**: For median/quantile with raw pointer inner loop
- **CSV fast reader**: Flat `FieldGrid` (no 2D array), custom `fastParseDouble` for `[-]digits[.digits]` (avoids strtod), reusable strtod buffer (1 alloc vs 6M), switch-based NA matching by field length
- **Typed merge**: Direct Double/String hash, not `formattedValue` → String
- **Optimized filter**: Mask → index array conversion (avoids branch misprediction), then index-based gather per column
- **Lazy evaluation**: Query optimizer eliminates intermediate DataFrames via filter fusion, predicate pushdown, projection pushdown
- **Compiler flags**: `-O` Swift, `-O3` for vendored C libraries

*Benchmarked on Apple M2 Max, 32GB RAM, macOS 15, Swift 6.0 Release, Python 3.11, pandas 2.2, NumPy 1.26*

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
- [x] Python vs Swift side-by-side benchmark suite (`benchmarks/benchmark_pandas.py`)
- [x] 30 individual detailed benchmark scripts (`benchmarks/tests/`)
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
- [x] Lazy evaluation engine (`LazyDataFrame` with query plan)
- [x] Query optimizer (filter fusion, predicate pushdown, projection pushdown)
- [x] Inspectable predicate expression tree (`ColumnPredicate`, `Col` operators)
- [x] CSV reader optimization (flat field grid, fast double parser, pandas-parity read speed)
- [x] Series arithmetic vDSP optimization
- [x] GroupBy optimization (cached factorize, hash precheck, two-pass accumulate, adaptive GPU/CPU dispatch)
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
