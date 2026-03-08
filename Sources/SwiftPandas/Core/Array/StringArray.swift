// ===----------------------------------------------------------------------===//
//
// StringArray.swift
// SwiftPandas
//
// This file defines ``StringArray``, the specialized array type for string
// column data. Unlike numeric types which can be stored in fixed-stride
// ``NativeArray<T>`` buffers, strings are variable-length and cannot be laid
// out contiguously in a single typed buffer. Therefore, ``StringArray`` uses
// `[String?]` as its backing storage, where `nil` entries represent NA
// (missing) values.
//
// ## Why [String?] instead of NativeArray + bitmap?
//
// The ``NativeArray<T>`` / ``NullableArray<T>`` approach works well for
// fixed-size types (Double, Int64, Bool) because:
//   - Elements have uniform stride, enabling pointer arithmetic and vDSP.
//   - The data buffer can be passed directly to Accelerate functions.
//
// Strings violate both assumptions: each String has a different byte length,
// and there is no Accelerate function for string operations. Using Swift's
// native `[String?]` gives us:
//   - Automatic ARC-managed storage for each string.
//   - Natural `nil` representation for missing values (no separate bitmap).
//   - Compatibility with Swift standard library algorithms.
//
// The tradeoff is that per-element access has ARC overhead and the array is
// not contiguous at the byte level. For string-heavy workloads, the dominant
// cost is typically hashing and comparison, not memory layout.
//
// ## FNV-1a hash-based factorize
//
// The ``factorize()`` method is the most performance-critical operation on
// ``StringArray``, as it is called during every GroupBy on a string key column.
// Rather than using Swift's standard ``Dictionary``, it implements a custom
// open-addressing hash table with FNV-1a hashing for several reasons:
//
//   1. **FNV-1a hashing via raw UTF-8 bytes**: The hash is computed by
//      iterating over the string's UTF-8 bytes directly (using
//      ``withContiguousStorageIfAvailable`` for zero-copy access when the
//      string's storage is contiguous, falling back to the UTF8View iterator
//      otherwise). This avoids the overhead of Swift's Hasher (which includes
//      per-process random seeding and SipHash).
//
//   2. **Open-addressing with linear probing**: The hash table is a flat
//      `UnsafeMutablePointer<Int32>` array where each slot stores either -1
//      (empty) or the index into the uniques array. Linear probing
//      (`pos = (pos + 1) & mask`) provides excellent cache locality for
//      sequential lookups.
//
//   3. **Hash caching for O(1) resizes**: When the table exceeds 70% load
//      factor, it is doubled in size. Rather than re-hashing all unique keys
//      (which would require re-iterating each string's UTF-8 bytes), the hash
//      values are cached in a ``ContiguousArray<Int>`` and reused during
//      re-insertion. This makes resize O(uniqueCount) instead of
//      O(totalStringBytes).
//
//   4. **Hash pre-check before string comparison**: During probe sequences,
//      the cached hash of the candidate is compared before performing the
//      full string equality check. Since hash collisions are rare with
//      FNV-1a on typical string data, this short-circuits most comparisons
//      to a single integer comparison.
//
// ===----------------------------------------------------------------------===//

/// A specialized array type for string data with NA support.
///
/// ``StringArray`` backs every ``.string`` column in a ``DataFrame``. It
/// stores strings as `[String?]` where `nil` represents missing values. This
/// is simpler than the ``NativeArray`` + ``BitVector`` approach used for
/// numeric types, because strings are variable-length and do not benefit from
/// contiguous fixed-stride storage.
///
/// ## Key operations
///
/// - **take/filter**: O(k) gather by index or boolean mask.
/// - **unique**: O(n) deduplication preserving first-occurrence order.
/// - **factorize**: O(n) encoding to integer codes using a custom FNV-1a
///   open-addressing hash table (the hot path for GroupBy on string keys).
/// - **argsort**: O(n log n) indirect sort with NA-last (ascending) or
///   NA-first (descending) convention.
public struct StringArray {
    /// The underlying storage: an array of optional strings.
    ///
    /// `nil` entries represent NA (missing) values. Non-nil entries are valid
    /// string data. The array's index space directly corresponds to the logical
    /// column positions.
    internal var storage: [String?]

    // MARK: - Initializers

    /// Create a ``StringArray`` from an array of optional strings.
    ///
    /// - Parameter elements: The source data. `nil` entries become NA positions.
    public init(_ elements: [String?]) {
        self.storage = elements
    }

    /// Create a ``StringArray`` from an array of non-optional strings (no NAs).
    ///
    /// - Parameter elements: The source data. All positions will be valid.
    ///
    /// Each element is wrapped in `Optional<String>` for uniform storage.
    public init(_ elements: [String]) {
        self.storage = elements.map { $0 as String? }
    }

    /// Create an empty ``StringArray`` with zero elements.
    public init() {
        self.storage = []
    }

    // MARK: - Access

    /// The number of elements (including NAs).
    public var count: Int { storage.count }

    /// Whether the array contains zero elements.
    public var isEmpty: Bool { storage.isEmpty }

    /// Approximate memory usage in bytes.
    ///
    /// Computed as the sum of UTF-8 byte lengths of all non-nil strings. This
    /// does not account for Swift String object overhead, ARC reference
    /// counting metadata, or the `[String?]` array's own allocation overhead,
    /// so it is a lower bound on true memory usage.
    public var nbytes: Int {
        storage.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
    }

    /// The number of valid (non-NA) values.
    ///
    /// - Complexity: O(n) -- iterates the array counting non-nil entries.
    ///   Unlike ``NullableArray``'s O(1) ``popcount``, there is no precomputed
    ///   count because `[String?]` does not maintain a bitmap.
    public var validCount: Int {
        storage.count { $0 != nil }
    }

    /// The number of NA (missing) values.
    public var naCount: Int {
        count - validCount
    }

    /// Access the element at the given position.
    ///
    /// - Returns: The string at that position, or `nil` if it is NA.
    /// - Precondition: `index` must be in `0..<count`.
    public subscript(index: Int) -> String? {
        get {
            precondition(index >= 0 && index < count, "Index \(index) out of range")
            return storage[index]
        }
        set {
            precondition(index >= 0 && index < count, "Index \(index) out of range")
            storage[index] = newValue
        }
    }

    /// Produce a Boolean mask where `true` indicates an NA position.
    ///
    /// - Returns: An array of length ``count`` where `result[i] == true` iff
    ///   `storage[i]` is `nil`.
    public func isNA() -> [Bool] {
        storage.map { $0 == nil }
    }

    // MARK: - Operations

    /// Return a deep copy of this string array.
    ///
    /// Because `[String?]` is a Swift value type (Array is CoW), this creates
    /// an independent copy that will not be affected by mutations to the
    /// original.
    public func copy() -> StringArray {
        StringArray(storage)
    }

    /// Gather elements at the specified integer positions into a new array.
    ///
    /// - Parameter indices: An array of zero-based positions. An index of `-1`
    ///   or any out-of-range value produces `nil` (NA) in the output.
    /// - Returns: A new ``StringArray`` of length `indices.count`.
    ///
    /// Uses ``withUnsafeBufferPointer`` on the indices array to avoid
    /// per-element bounds checking overhead in the inner loop.
    ///
    /// - Complexity: O(indices.count)
    public func take(indices: [Int]) -> StringArray {
        let n = indices.count
        let srcCount = count
        var result = [String?]()
        result.reserveCapacity(n)
        indices.withUnsafeBufferPointer { idx in
            for i in 0..<n {
                let j = idx[i]
                result.append((j >= 0 && j < srcCount) ? storage[j] : nil)
            }
        }
        return StringArray(result)
    }

    /// Gather elements where a Boolean mask is `true` into a new array.
    ///
    /// - Parameters:
    ///   - mask: A Boolean array of the same length as this array.
    ///   - trueCount: The precomputed number of `true` values in `mask`.
    /// - Returns: A new ``StringArray`` of length `trueCount`.
    /// - Complexity: O(n) where n is the mask length.
    public func take(mask: [Bool], trueCount: Int) -> StringArray {
        var result = [String?]()
        result.reserveCapacity(trueCount)
        mask.withUnsafeBufferPointer { m in
            for i in 0..<m.count {
                if m[i] { result.append(storage[i]) }
            }
        }
        return StringArray(result)
    }

    /// Return unique values, preserving the order of first occurrence.
    ///
    /// Uses a ``Set<String>`` to track seen values. The first time a string is
    /// encountered, it is appended to the result. If any NA positions exist,
    /// exactly one `nil` entry is included in the output (at the position of
    /// the first NA encountered).
    ///
    /// - Returns: A new ``StringArray`` with no duplicate values.
    /// - Complexity: O(n) average (hash set lookups are amortized O(1)).
    public func unique() -> StringArray {
        var seen = Set<String>()
        var result = [String?]()
        var hasNA = false
        for s in storage {
            if let s = s {
                if seen.insert(s).inserted {
                    result.append(s)
                }
            } else if !hasNA {
                hasNA = true
                result.append(nil)
            }
        }
        return StringArray(result)
    }

    /// Encode each string as an integer code referencing a table of unique
    /// values (factorization).
    ///
    /// This is the **performance-critical** method for GroupBy on string key
    /// columns. It uses a custom open-addressing hash table with FNV-1a
    /// hashing rather than Swift's standard ``Dictionary`` for maximum
    /// throughput.
    ///
    /// ## Algorithm
    ///
    /// 1. **Hash table setup**: An `UnsafeMutablePointer<Int32>` array is
    ///    allocated with initial capacity 256 (or larger, based on a heuristic
    ///    estimate of unique count). All slots are initialized to -1 (empty).
    ///    The capacity is always a power of two so that modular arithmetic can
    ///    use bitwise AND (`pos & mask`) instead of the expensive `%` operator.
    ///
    /// 2. **FNV-1a hashing**: For each non-nil string, the hash is computed by
    ///    XOR-folding each UTF-8 byte with the running hash and multiplying by
    ///    the FNV prime (1099511628211). The initial basis is the standard
    ///    FNV-1a 64-bit offset basis (14695981039346656037). The implementation
    ///    attempts ``withContiguousStorageIfAvailable`` on the string's UTF-8
    ///    view for zero-copy pointer access; if the string's storage is not
    ///    contiguous (e.g., bridged NSString), it falls back to iterating the
    ///    ``UTF8View``.
    ///
    /// 3. **Probe and insert**: Using linear probing (`pos = (pos + 1) & mask`),
    ///    the algorithm searches for either an empty slot (new unique key) or a
    ///    matching existing key. Before performing a full string comparison, the
    ///    cached hash of the candidate is compared as a fast pre-check --
    ///    strings with different hashes cannot be equal, so most probes
    ///    short-circuit on a single integer comparison.
    ///
    /// 4. **Dynamic resize at 70% load factor**: When the number of unique keys
    ///    exceeds 70% of the table capacity (`uniqueKeys.count * 10 > cap * 7`),
    ///    the table is doubled in size. The resize re-inserts all existing keys
    ///    using the **cached hash values** (not re-hashing the strings), making
    ///    resize O(uniqueCount) rather than O(totalStringBytes).
    ///
    /// 5. **NA handling**: `nil` entries in the input are assigned code `-1`
    ///    (the default in the pre-allocated codes array) and are not inserted
    ///    into the hash table.
    ///
    /// - Returns: A tuple `(codes, uniques)` where:
    ///   - `codes` is an `[Int]` of length ``count``. `codes[i]` is the index
    ///     into `uniques` for non-nil strings, or `-1` for NA positions.
    ///   - `uniques` is a ``StringArray`` of distinct non-nil strings in order
    ///     of first occurrence. (Note: uniques may contain `nil` entries at
    ///     the end from the internal `[String?]` representation, but these are
    ///     not referenced by any code.)
    ///
    /// - Complexity: O(n) average, O(n * uniqueCount) worst case (hash collision
    ///   degeneracy, extremely unlikely with FNV-1a).
    public func factorize() -> (codes: [Int], uniques: StringArray) {
        let n = count
        guard n > 0 else { return ([], StringArray()) }

        // Pre-allocate codes array (-1 = NA)
        var codes = [Int](repeating: -1, count: n)
        var uniqueKeys = [String?]()
        uniqueKeys.reserveCapacity(128)

        // Open-addressing hash table with FNV-1a
        // Pre-size for estimated unique count (heuristic: min(n, 65536))
        let estimatedUniques = Swift.min(n, 65536)
        var cap = 256
        while cap < estimatedUniques * 2 { cap &*= 2 }
        var mask = cap &- 1
        var table = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        table.initialize(repeating: -1, count: cap)

        // Cache hash values for O(1) resize (avoids re-hashing all unique keys)
        var hashCache = ContiguousArray<Int>()
        hashCache.reserveCapacity(estimatedUniques)

        // Use raw buffer pointer to skip per-element bounds checking
        storage.withUnsafeBufferPointer { storageBuf in
            for i in 0..<n {
                guard let s = storageBuf[i] else { continue }

                // FNV-1a hash via withUTF8 raw pointer (avoids UTF8View iterator overhead)
                let hi: Int
                if let result = s.utf8.withContiguousStorageIfAvailable({ buf -> Int in
                    var h: UInt = 14695981039346656037
                    for j in 0..<buf.count {
                        h ^= UInt(buf[j])
                        h &*= 1099511628211
                    }
                    return Int(bitPattern: h)
                }) {
                    hi = result
                } else {
                    var h: UInt = 14695981039346656037
                    for byte in s.utf8 {
                        h ^= UInt(byte)
                        h &*= 1099511628211
                    }
                    hi = Int(bitPattern: h)
                }

                var pos = hi & mask
                while true {
                    let idx = Int(table[pos])
                    if idx < 0 {
                        // New unique key -- insert
                        let code = uniqueKeys.count
                        uniqueKeys.append(s)
                        hashCache.append(hi)
                        table[pos] = Int32(code)
                        codes[i] = code
                        // Resize at 70% load factor
                        if uniqueKeys.count &* 10 > cap &* 7 {
                            let oldTable = table
                            cap &*= 2
                            mask = cap &- 1
                            table = .allocate(capacity: cap)
                            table.initialize(repeating: -1, count: cap)
                            for j in 0..<uniqueKeys.count {
                                var p = hashCache[j] & mask
                                while table[p] >= 0 { p = (p &+ 1) & mask }
                                table[p] = Int32(j)
                            }
                            oldTable.deallocate()
                        }
                        break
                    }
                    // Hash precheck: skip full string comparison if hashes differ
                    if hashCache[idx] == hi && uniqueKeys[idx]! == s {
                        codes[i] = idx
                        break
                    }
                    pos = (pos &+ 1) & mask
                }
            }
        }

        table.deallocate()
        return (codes, StringArray(uniqueKeys))
    }

    /// Replace all NA positions with the given constant string.
    ///
    /// - Parameter value: The fill value for every `nil` position.
    /// - Returns: A new ``StringArray`` with no NA values.
    public func fillNA(value: String) -> StringArray {
        StringArray(storage.map { $0 ?? value })
    }

    /// Extract only the valid (non-NA) strings into a plain `[String]`.
    ///
    /// - Returns: An array of non-nil strings in their original order.
    /// - Complexity: O(n)
    public func dropNA() -> [String] {
        storage.compactMap { $0 }
    }

    /// Return the indices that would sort this array.
    ///
    /// - Parameter ascending: If `true`, sort in ascending lexicographic order;
    ///   otherwise descending.
    /// - Returns: An array of indices of length ``count``.
    ///
    /// NA values are placed at the **end** for ascending sorts and at the
    /// **beginning** for descending sorts, matching pandas' default
    /// `na_position="last"` behavior for ascending and `na_position="first"`
    /// for descending.
    ///
    /// - Complexity: O(n log n)
    public func argsort(ascending: Bool = true) -> [Int] {
        let indexed = storage.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            switch (a.1, b.1) {
            case (nil, nil): return false
            case (nil, _): return !ascending // NAs go to end for ascending
            case (_, nil): return ascending
            case let (l?, r?): return ascending ? l < r : l > r
            }
        }
        return sorted.map { $0.0 }
    }
}

// MARK: - CustomStringConvertible

/// Human-readable display: shows up to the first 10 elements (quoted strings,
/// "NA" for nil), followed by an ellipsis and total count if longer.
extension StringArray: CustomStringConvertible {
    public var description: String {
        let elements = storage.prefix(10).map { s -> String in
            s.map { "\"\($0)\"" } ?? "NA"
        }.joined(separator: ", ")
        if count > 10 {
            return "[\(elements), ... (\(count) elements)]"
        }
        return "[\(elements)]"
    }
}

// MARK: - Equatable

/// Element-wise equality. Two ``StringArray`` values are equal when their
/// underlying `[String?]` arrays are equal (same count, same elements at
/// every position, including `nil == nil`).
extension StringArray: Equatable {}

// MARK: - Sendable

/// ``StringArray`` is unconditionally ``Sendable`` because `[String?]` is a
/// value type composed of ``Sendable`` elements (``String`` and ``Optional``
/// are both ``Sendable``).
extension StringArray: Sendable {}
