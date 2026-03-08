// MARK: - Index.swift
// ===========================================================================
// Index System for SwiftPandas
// ===========================================================================
//
// This file defines the axis-labeling infrastructure used by `Series` and
// `DataFrame`.  Every pandas-like data structure needs an index that maps
// human-readable labels (strings, integers, ranges) to positional offsets
// (0-based `Int` positions into the underlying data arrays).
//
// The design mirrors Python pandas' index hierarchy:
//
//   PandasIndex (protocol)
//     ├── RangeIndex    — default, memory-efficient, no heap allocation
//     ├── StringIndex   — hash-backed [String:Int] lookup table
//     └── Int64Index    — hash-backed [Int64:Int] lookup table
//
// All concrete index types guarantee O(1) label-to-position lookup via
// `getLocation(of:)`.  RangeIndex achieves this through arithmetic on its
// start/stop/step triple; StringIndex and Int64Index achieve it through
// a pre-built Swift `Dictionary`.
//
// Thread Safety
// -------------
// Every type in this file conforms to `Sendable`.  The concrete structs are
// value types whose stored properties are either `let` constants or value-type
// dictionaries, so they are safe to share across concurrency domains with no
// additional synchronization.
//
// Non-Unique Labels
// -----------------
// StringIndex and Int64Index permit non-unique labels.  When duplicate labels
// exist, `getLocation(of:)` returns the position of the *first* occurrence
// (the one with the lowest integer offset).  The `isUnique` property lets
// callers detect duplicates cheaply — it compares the dictionary count against
// the values array count, which is O(1).
// ===========================================================================

/// Protocol that all axis-label types must conform to.
///
/// `PandasIndex` is the single abstraction point for axis labels in SwiftPandas.
/// It provides a contract that every index implementation must satisfy:
///
/// - **O(1) lookup**: `getLocation(of:)` must resolve a label to its positional
///   offset in constant time (amortized).  This is critical for alignment
///   operations where two Series with different labels must be joined.
/// - **Containment check**: `contains(_:)` must run in O(1) as well.
/// - **Uniqueness query**: `isUnique` must be answerable without a linear scan
///   (concrete types typically cache this or derive it from stored counts).
/// - **Materialisation**: `values` produces a dense `[Label]` array.  For
///   `RangeIndex` this involves allocation (since it stores no array); for
///   hash-backed indexes it simply returns the already-stored array.
///
/// Conformers must also satisfy `CustomStringConvertible` (for pretty-printing
/// in REPL / debug contexts) and `Sendable` (for safe use in structured
/// concurrency).
///
/// ## Choosing an Index Type
///
/// | Type          | Best for                        | Memory       | Lookup |
/// |---------------|---------------------------------|--------------|--------|
/// | `RangeIndex`  | Default positional indexing     | O(1) — three `Int`s | O(1) arithmetic |
/// | `StringIndex` | Named row/column labels         | O(n) array + O(n) dict | O(1) hash |
/// | `Int64Index`  | Non-contiguous integer labels   | O(n) array + O(n) dict | O(1) hash |
public protocol PandasIndex: CustomStringConvertible, Sendable {
    /// The type of each individual label.  Must be `Hashable` so that
    /// dictionary-backed indexes can build their lookup tables, and `Sendable`
    /// so the index remains safe across concurrency domains.
    associatedtype Label: Hashable & Sendable

    /// A dense array of every label in positional order.
    ///
    /// For `RangeIndex` this is computed on demand (allocates a new `[Int]`
    /// each call).  For `StringIndex` and `Int64Index` this returns the stored
    /// array with no copy (Swift COW semantics).
    var values: [Label] { get }

    /// The total number of labels in the index.
    ///
    /// This is always O(1).  `RangeIndex` computes it from its start/stop/step
    /// triple; hash-backed indexes return the count of their stored array.
    var count: Int { get }

    /// Resolve a label to its positional (0-based) offset.
    ///
    /// - Parameter label: The label to look up.
    /// - Returns: The integer position, or `nil` if the label is not present.
    ///
    /// For non-unique indexes (e.g., `StringIndex` with duplicate labels) this
    /// returns the position of the *first* occurrence — the one inserted first
    /// during index construction.
    ///
    /// - Complexity: O(1) amortized for all concrete index types.
    func getLocation(of label: Label) -> Int?

    /// Check whether the index contains the given label.
    ///
    /// - Parameter label: The label to test for membership.
    /// - Returns: `true` if the label is present, `false` otherwise.
    ///
    /// - Complexity: O(1) amortized.  Equivalent to `getLocation(of:) != nil`
    ///   but may be marginally cheaper for some implementations.
    func contains(_ label: Label) -> Bool

    /// Whether every label in the index is unique (no duplicates).
    ///
    /// When `true`, `getLocation(of:)` is a bijection — every label maps to
    /// exactly one position and vice-versa.  `RangeIndex` always returns `true`
    /// because its labels are computed from an arithmetic sequence and cannot
    /// repeat.  Hash-backed indexes compare their dictionary count to their
    /// array count — if they differ, duplicates exist.
    ///
    /// - Complexity: O(1).
    var isUnique: Bool { get }
}

// MARK: - RangeIndex

/// A memory-efficient index representing a contiguous (or strided) range of
/// integer labels, analogous to Python pandas' `RangeIndex`.
///
/// `RangeIndex` stores only three scalar values — `start`, `stop`, and `step`
/// — so its memory footprint is O(1) regardless of the logical number of
/// labels it represents.  This makes it the ideal default index for newly
/// created `Series` and `DataFrame` objects that have no explicit labels.
///
/// ## Label Computation
///
/// Labels are computed on the fly using the formula:
///
///     label(position) = start + position * step
///
/// The reverse mapping (`getLocation(of:)`) inverts this formula:
///
///     position = (label - start) / step    (iff (label - start) % step == 0)
///
/// Both directions are pure arithmetic and therefore O(1) with no dictionary
/// overhead.
///
/// ## Uniqueness
///
/// A `RangeIndex` is *always* unique.  Since labels are generated by an
/// arithmetic sequence with a non-zero step, no two distinct positions can
/// produce the same label.
///
/// ## Example
///
///     let idx = RangeIndex(start: 0, stop: 100, step: 2)
///     // Represents labels: 0, 2, 4, ..., 98  (50 elements, O(1) storage)
///     idx.getLocation(of: 10)  // 5
///     idx.getLocation(of: 3)   // nil — not on the step grid
///
public struct RangeIndex: PandasIndex, Sendable {
    public typealias Label = Int

    /// The first label in the range (inclusive).
    public let start: Int

    /// The upper bound of the range (exclusive), following Python's half-open
    /// interval convention.
    public let stop: Int

    /// The distance between consecutive labels.  Must be non-zero.
    /// Positive steps produce ascending labels; negative steps produce
    /// descending labels.
    public let step: Int

    /// Create a `RangeIndex` with explicit start, stop, and step values.
    ///
    /// - Parameters:
    ///   - start: The first label (default `0`).
    ///   - stop:  The exclusive upper bound.
    ///   - step:  The stride between labels (default `1`).  A `step` of zero
    ///            triggers a precondition failure.
    ///
    /// - Precondition: `step != 0`.
    public init(start: Int = 0, stop: Int, step: Int = 1) {
        precondition(step != 0, "Step cannot be zero")
        self.start = start
        self.stop = stop
        self.step = step
    }

    /// Convenience initializer that creates a `RangeIndex` equivalent to
    /// `0 ..< count` with step 1.
    ///
    /// This is the most common construction path — it mirrors the default
    /// positional index that pandas assigns to a `DataFrame` or `Series`
    /// when no explicit index is provided.
    ///
    /// - Parameter count: The number of labels (i.e., `stop` value).
    public init(_ count: Int) {
        self.start = 0
        self.stop = count
        self.step = 1
    }

    /// The number of labels in this index.
    ///
    /// Computed via ceiling division on the start/stop/step triple.
    /// The guard clause handles the empty-range edge case where the direction
    /// of `step` is incompatible with the start-to-stop direction (e.g.,
    /// `start=5, stop=0, step=1`).
    ///
    /// - Complexity: O(1).
    public var count: Int {
        guard step > 0 ? start < stop : start > stop else { return 0 }
        return (stop - start + step - (step > 0 ? 1 : -1)) / step
    }

    /// Materialise all labels into a heap-allocated array.
    ///
    /// Unlike `StringIndex.values` and `Int64Index.values`, this property
    /// allocates a fresh `[Int]` on every access because `RangeIndex` does
    /// not store an array internally.  Prefer positional subscripting or
    /// `getLocation(of:)` in hot paths to avoid this allocation.
    ///
    /// - Complexity: O(n) time and space where n is `count`.
    public var values: [Int] {
        stride(from: start, to: stop, by: step).map { $0 }
    }

    /// Resolve a label to its positional offset using arithmetic inversion.
    ///
    /// The method first checks that `(label - start)` is evenly divisible by
    /// `step` — if not, the label does not lie on the range grid and `nil` is
    /// returned.  It then verifies the computed position is within bounds.
    ///
    /// - Parameter label: The integer label to look up.
    /// - Returns: The 0-based position, or `nil` if the label is not in this range.
    /// - Complexity: O(1).
    public func getLocation(of label: Int) -> Int? {
        guard (label - start) % step == 0 else { return nil }
        let pos = (label - start) / step
        guard pos >= 0 && pos < count else { return nil }
        return pos
    }

    /// Check whether the given integer label falls on this range's grid.
    ///
    /// - Parameter label: The integer label to test.
    /// - Returns: `true` if the label is a member of this range.
    /// - Complexity: O(1).  Delegates to `getLocation(of:)`.
    public func contains(_ label: Int) -> Bool {
        getLocation(of: label) != nil
    }

    /// Always returns `true` — an arithmetic sequence with non-zero step
    /// cannot produce duplicate labels.
    public var isUnique: Bool { true }

    /// Retrieve the label at a given positional offset.
    ///
    /// - Parameter position: A 0-based position.  Must satisfy
    ///   `0 <= position < count`.
    /// - Returns: The label at that position, computed as
    ///   `start + position * step`.
    ///
    /// - Precondition: `position` is in bounds.
    /// - Complexity: O(1).
    public subscript(position: Int) -> Int {
        precondition(position >= 0 && position < count, "Position \(position) out of range")
        return start + position * step
    }

    /// A pandas-style string representation, e.g.
    /// `RangeIndex(start=0, stop=100, step=1)`.
    public var description: String {
        "RangeIndex(start=\(start), stop=\(stop), step=\(step))"
    }
}

// MARK: - StringIndex

/// An index backed by an array of `String` labels and a `[String: Int]`
/// dictionary for O(1) label-to-position lookup.
///
/// `StringIndex` is the primary index type for named axes — for example,
/// column names in a `DataFrame` or labelled rows in a `Series`.
///
/// ## Internal Layout
///
/// ```
/// values:  ["a", "b", "c", "a"]     ← preserves insertion order & duplicates
/// lookup:  ["a": 0, "b": 1, "c": 2] ← maps each unique label to its FIRST position
/// ```
///
/// The `values` array retains the original order and all duplicates, while the
/// `lookup` dictionary records only the first occurrence of each label.  This
/// means:
///
/// - `getLocation(of: "a")` returns `0`, not `3`.
/// - `isUnique` returns `false` because `lookup.count (3) != values.count (4)`.
///
/// ## Duplicate-Label Semantics ("Keeps First")
///
/// During construction the initializer iterates over the input labels and
/// inserts into `lookup` only when the key is absent (`if lookup[label] == nil`).
/// This guarantees that the first positional occurrence wins.  Callers that
/// need *all* positions of a duplicate label must scan `values` directly.
///
/// ## Performance
///
/// | Operation           | Complexity |
/// |---------------------|------------|
/// | `init(_:)`          | O(n) — one pass to build the dictionary |
/// | `getLocation(of:)`  | O(1) amortized — dictionary lookup      |
/// | `contains(_:)`      | O(1) amortized                          |
/// | `isUnique`          | O(1) — compares two stored counts       |
/// | `count`             | O(1)                                    |
///
/// The dictionary is allocated with `minimumCapacity: labels.count` to reduce
/// rehashing during construction.
public struct StringIndex: PandasIndex, Sendable {
    public typealias Label = String

    /// The full array of labels in their original insertion order, including
    /// any duplicates.
    public let values: [String]

    /// Internal hash map from each unique label to the position of its first
    /// occurrence in `values`.
    private let lookup: [String: Int]

    /// Create a `StringIndex` from an array of string labels.
    ///
    /// - Parameter labels: The labels in positional order.  Duplicates are
    ///   permitted; the lookup dictionary will record only the first occurrence
    ///   of each duplicate label.
    ///
    /// - Complexity: O(n) where n is `labels.count`.
    public init(_ labels: [String]) {
        self.values = labels
        var lookup = [String: Int](minimumCapacity: labels.count)
        for (i, label) in labels.enumerated() {
            if lookup[label] == nil {
                lookup[label] = i
            }
        }
        self.lookup = lookup
    }

    /// The number of labels (including duplicates).
    ///
    /// - Complexity: O(1).
    public var count: Int { values.count }

    /// Look up the positional offset of a string label.
    ///
    /// When multiple positions share the same label, this returns the *first*
    /// (lowest-numbered) position.
    ///
    /// - Parameter label: The string label to locate.
    /// - Returns: The 0-based position, or `nil` if the label is absent.
    /// - Complexity: O(1) amortized (dictionary lookup).
    public func getLocation(of label: String) -> Int? {
        lookup[label]
    }

    /// Test whether the given label exists in this index.
    ///
    /// - Parameter label: The string label to search for.
    /// - Returns: `true` if at least one position carries this label.
    /// - Complexity: O(1) amortized.
    public func contains(_ label: String) -> Bool {
        lookup[label] != nil
    }

    /// Whether every label in this index is unique.
    ///
    /// This is determined by comparing the number of unique keys in the
    /// `lookup` dictionary to the total number of entries in `values`.
    /// If they differ, at least one label appears more than once.
    ///
    /// - Complexity: O(1).
    public var isUnique: Bool {
        lookup.count == values.count
    }

    /// A pandas-style string representation that shows up to the first five
    /// labels.  Labels beyond the fifth are elided with `...` and a total
    /// length is appended.
    public var description: String {
        let labels = values.prefix(5).map { "'\($0)'" }.joined(separator: ", ")
        if count > 5 {
            return "Index([\(labels), ...], length=\(count))"
        }
        return "Index([\(labels)])"
    }
}

// MARK: - Int64Index

/// An index backed by an array of `Int64` labels and a `[Int64: Int]`
/// dictionary for O(1) label-to-position lookup.
///
/// `Int64Index` serves the same role as `StringIndex` but for integer labels
/// that are *not* representable as a contiguous `RangeIndex` (e.g., database
/// primary keys, timestamps stored as epoch seconds, or any non-contiguous /
/// non-uniformly-spaced set of integers).
///
/// ## Duplicate-Label Semantics
///
/// Identical to `StringIndex`: the lookup dictionary records only the first
/// positional occurrence of each label.  See the `StringIndex` documentation
/// for a detailed explanation.
///
/// ## Why Int64 Instead of Int?
///
/// Using a fixed-width `Int64` ensures consistent behaviour across 32-bit and
/// 64-bit platforms and matches the precision of pandas' default integer dtype
/// (`int64`).  A convenience initializer `init(ints:)` accepts `[Int]` for
/// ergonomic use on 64-bit Apple platforms where `Int` is already 64 bits.
///
/// ## Performance
///
/// All lookup and containment operations are O(1) amortized, matching
/// `StringIndex`.  Construction is O(n).
public struct Int64Index: PandasIndex, Sendable {
    public typealias Label = Int64

    /// The full array of `Int64` labels in their original insertion order,
    /// including any duplicates.
    public let values: [Int64]

    /// Internal hash map from each unique label to the position of its first
    /// occurrence in `values`.
    private let lookup: [Int64: Int]

    /// Create an `Int64Index` from an array of `Int64` labels.
    ///
    /// - Parameter labels: The labels in positional order.  Duplicates are
    ///   permitted; the lookup dictionary records only the first occurrence.
    ///
    /// - Complexity: O(n) where n is `labels.count`.
    public init(_ labels: [Int64]) {
        self.values = labels
        var lookup = [Int64: Int](minimumCapacity: labels.count)
        for (i, label) in labels.enumerated() {
            if lookup[label] == nil {
                lookup[label] = i
            }
        }
        self.lookup = lookup
    }

    /// Convenience initializer that converts an `[Int]` array to `[Int64]`.
    ///
    /// This avoids forcing callers to litter their code with `Int64(…)` casts
    /// when working on platforms where `Int` is already 64 bits.
    ///
    /// - Parameter labels: An array of `Int` values to be widened to `Int64`.
    public init(ints labels: [Int]) {
        self.init(labels.map { Int64($0) })
    }

    /// The number of labels (including duplicates).
    ///
    /// - Complexity: O(1).
    public var count: Int { values.count }

    /// Look up the positional offset of an `Int64` label.
    ///
    /// When duplicate labels exist, this returns the first (lowest-numbered)
    /// position.
    ///
    /// - Parameter label: The `Int64` label to locate.
    /// - Returns: The 0-based position, or `nil` if the label is absent.
    /// - Complexity: O(1) amortized (dictionary lookup).
    public func getLocation(of label: Int64) -> Int? {
        lookup[label]
    }

    /// Test whether the given `Int64` label exists in this index.
    ///
    /// - Parameter label: The label to search for.
    /// - Returns: `true` if at least one position carries this label.
    /// - Complexity: O(1) amortized.
    public func contains(_ label: Int64) -> Bool {
        lookup[label] != nil
    }

    /// Whether every label in this index is unique.
    ///
    /// Compares the count of unique dictionary keys to the total array length.
    ///
    /// - Complexity: O(1).
    public var isUnique: Bool {
        lookup.count == values.count
    }

    /// A pandas-style string representation showing up to five labels, with
    /// elision for longer indexes.
    public var description: String {
        let labels = values.prefix(5).map { "\($0)" }.joined(separator: ", ")
        if count > 5 {
            return "Int64Index([\(labels), ...], length=\(count))"
        }
        return "Int64Index([\(labels)])"
    }
}
