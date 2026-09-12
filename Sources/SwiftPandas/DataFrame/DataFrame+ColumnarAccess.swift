// ===----------------------------------------------------------------------===//
//
// DataFrame+ColumnarAccess.swift — zero-copy columnar access (D3)
//
// The enabler for external bridges — Arrow C data interface, parquet
// codecs living host-side, GPU upload — without per-cell boxing in either
// direction:
//
//   * **Borrow out:** `withUnsafeDoubleBuffer` (+ int64/bool analogues)
//     hands the caller the column's contiguous storage and its validity
//     bitmap for the duration of a closure. No copies, no per-element
//     `T?` construction. String columns are borrowed as their backing
//     `[String?]` (variable-length data has no fixed-stride buffer to
//     expose).
//
//   * **Move in:** `Column.init(takingDoubles:validity:)` (+ analogues)
//     wraps prebuilt arrays in at most one bulk copy — never a
//     per-element append path.
//
// Validity is exposed in its native packed form, `ColumnValidity`:
// LSB-first `UInt64` words where a set bit means *valid* — the same
// convention as the Arrow validity bitmap, so an Arrow bridge can hand
// the words straight through. `nil` validity means "no NAs" (mirroring
// Arrow's omitted-buffer convention for null_count == 0); use
// `ColumnValidity.boolArray` when a caller wants unpacked flags and can
// afford the 8× expansion.
//
// ===----------------------------------------------------------------------===//

/// A borrowed view of a column's validity bitmap, valid only inside the
/// `withUnsafe*Buffer` closure that produced it.
///
/// Layout: LSB-first `UInt64` words, set bit = valid row — bit `i` of the
/// column is `(words[i / 64] >> (i % 64)) & 1`. This matches both
/// ``BitVector``'s internal layout (the view is a straight borrow) and the
/// Arrow specification's validity bitmap, modulo Arrow's byte-granularity
/// framing (Arrow reads the same bytes LSB-first, so the bit positions
/// agree on little-endian platforms).
public struct ColumnValidity {
    /// The packed validity words. The final word's bits at positions
    /// `>= count % 64` are zero by ``BitVector`` invariant.
    public let words: UnsafeBufferPointer<UInt64>
    /// The number of rows covered by the bitmap.
    public let count: Int

    /// Whether the row at `index` holds a valid value (`false` = NA).
    @inline(__always)
    public subscript(index: Int) -> Bool {
        precondition(index >= 0 && index < count, "Index \(index) out of range")
        return (words[index >> 6] >> UInt64(index & 63)) & 1 == 1
    }

    /// Unpacks the bitmap to one `Bool` per row (true = valid). O(n) and
    /// 8× the memory of the packed form — prefer the subscript or `words`
    /// for bulk work.
    public var boolArray: [Bool] {
        (0..<count).map { self[$0] }
    }
}

extension DataFrame {

    /// Borrows a `.double` column's contiguous storage for the duration of
    /// `body`.
    ///
    /// - Parameters:
    ///   - column: The column name.
    ///   - body: Receives the value buffer (one `Double` per row; NA
    ///     positions hold an unspecified placeholder) and the validity
    ///     bitmap, or `nil` validity when every row is valid.
    /// - Throws: ``DataFrameError/columnNotFound(_:)`` or
    ///   ``DataFrameError/typeMismatch(expected:got:)``; rethrows from `body`.
    public func withUnsafeDoubleBuffer<R>(
        _ column: String,
        _ body: (UnsafeBufferPointer<Double>, ColumnValidity?) throws -> R
    ) throws -> R {
        guard let col = columns[column] else {
            throw DataFrameError.columnNotFound(column)
        }
        guard case .double(let arr) = col else {
            throw DataFrameError.typeMismatch(expected: "float64",
                                              got: String(describing: col.dtype))
        }
        return try Self.withBorrowedBuffers(arr, body)
    }

    /// Borrows an `.int64` column's contiguous storage. See
    /// ``withUnsafeDoubleBuffer(_:_:)`` for the borrowing contract.
    public func withUnsafeInt64Buffer<R>(
        _ column: String,
        _ body: (UnsafeBufferPointer<Int64>, ColumnValidity?) throws -> R
    ) throws -> R {
        guard let col = columns[column] else {
            throw DataFrameError.columnNotFound(column)
        }
        guard case .int64(let arr) = col else {
            throw DataFrameError.typeMismatch(expected: "int64",
                                              got: String(describing: col.dtype))
        }
        return try Self.withBorrowedBuffers(arr, body)
    }

    /// Borrows a `.bool` column's contiguous storage. See
    /// ``withUnsafeDoubleBuffer(_:_:)`` for the borrowing contract.
    public func withUnsafeBoolBuffer<R>(
        _ column: String,
        _ body: (UnsafeBufferPointer<Bool>, ColumnValidity?) throws -> R
    ) throws -> R {
        guard let col = columns[column] else {
            throw DataFrameError.columnNotFound(column)
        }
        guard case .bool(let arr) = col else {
            throw DataFrameError.typeMismatch(expected: "bool",
                                              got: String(describing: col.dtype))
        }
        return try Self.withBorrowedBuffers(arr, body)
    }

    /// Borrows a `.string` column as its backing `[String?]` (`nil` = NA).
    ///
    /// The array is handed over without copying elements (CoW — it stays
    /// shared until the caller mutates their reference). Variable-length
    /// strings have no fixed-stride buffer, so this is the string
    /// analogue of the `withUnsafe*Buffer` family.
    public func withStringColumn<R>(
        _ column: String,
        _ body: ([String?]) throws -> R
    ) throws -> R {
        guard let col = columns[column] else {
            throw DataFrameError.columnNotFound(column)
        }
        guard case .string(let arr) = col else {
            throw DataFrameError.typeMismatch(expected: "string",
                                              got: String(describing: col.dtype))
        }
        return try body(arr.storage)
    }

    /// Scopes `body` over a nullable column's data buffer and — unless the
    /// column is all-valid — its borrowed mask words.
    private static func withBorrowedBuffers<T, R>(
        _ arr: NullableArray<T>,
        _ body: (UnsafeBufferPointer<T>, ColumnValidity?) throws -> R
    ) rethrows -> R {
        try arr.data.withUnsafeBufferPointer { data in
            if arr.mask.allValid {
                return try body(data, nil)
            }
            return try arr.mask.words.withUnsafeBufferPointer { words in
                try body(data, ColumnValidity(words: words, count: arr.count))
            }
        }
    }
}

// MARK: - Taking-ownership Column construction

extension Column {

    /// Wraps prebuilt `Double` storage as a column in at most one bulk
    /// copy — no per-element append path.
    ///
    /// - Parameters:
    ///   - values: One value per row. Positions marked invalid may hold
    ///     any placeholder.
    ///   - validity: `true` = valid, `false` = NA. Pass `nil` when every
    ///     row is valid (enables the column's `allValid` fast paths).
    /// - Precondition: `validity.count == values.count` when provided.
    public init(takingDoubles values: [Double], validity: [Bool]? = nil) {
        self = .double(Column.nullable(values, validity))
    }

    /// `Int64` analogue of ``init(takingDoubles:validity:)``.
    public init(takingInt64s values: [Int64], validity: [Bool]? = nil) {
        self = .int64(Column.nullable(values, validity))
    }

    /// `Bool` analogue of ``init(takingDoubles:validity:)``.
    public init(takingBools values: [Bool], validity: [Bool]? = nil) {
        self = .bool(Column.nullable(values, validity))
    }

    /// Wraps prebuilt string storage as a column; `nil` elements are NA.
    /// The array is adopted CoW-style — no element copies.
    public init(takingStrings values: [String?]) {
        self = .string(StringArray(values))
    }

    private static func nullable<T>(_ values: [T], _ validity: [Bool]?) -> NullableArray<T> {
        let data = NativeArray(values)
        guard let validity else {
            return NullableArray(data)
        }
        precondition(validity.count == values.count,
                     "validity count \(validity.count) != values count \(values.count)")
        return NullableArray(data: data, mask: BitVector(validity))
    }
}
