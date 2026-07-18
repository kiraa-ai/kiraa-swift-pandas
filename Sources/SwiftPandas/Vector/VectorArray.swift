// ===----------------------------------------------------------------------===//
//
// VectorArray.swift
// SwiftPandas
//
// Fixed-dimensionality Float32 vector storage for the `.floatVector` Column
// case: a flat, contiguous, row-major plane plus an Arrow-style validity
// bitmap. This one type owns every storage-layout decision for vector
// columns — no other file may depend on the plane layout, the zero-fill rule,
// or the norm cache.
//
// ## Invariants (established at construction, assumed everywhere else)
//
// - `dims >= 1`, immutable for the array's lifetime.
// - `plane.count == count * dims` and `validity.bitCount == count`.
// - A null row's plane slot is **zero-filled**. This is normative: it makes
//   SPB file bytes deterministic (the writer streams the plane verbatim) and
//   lets `Equatable` be synthesized safely.
// - `squaredNorms[i]` is exactly `VectorOps.dotF(row_i, row_i)`, computed once
//   at construction and *sliced* (never recomputed) by take/copy. The search
//   bit-parity contract explicitly permits this cache: `vDSP_dotpr(v, v)` on
//   the same bytes is bit-identical whenever computed. Null rows cache 0.
// - The plane always holds **raw** vectors — normalization is an explicit,
//   new-value operation only (see VectorSeriesOps.swift).
//
// ===----------------------------------------------------------------------===//

/// Flat contiguous Float32 vector storage: `count` rows of `dims` elements
/// each, with null support via a validity bitmap.
public struct VectorArray: Sendable, Equatable {
    /// Row-major plane of length `count * dims`. Null rows are zero-filled.
    internal var plane: NativeArray<Float>
    /// Validity bitmap: bit *i* set means row *i* holds a vector, cleared
    /// means row *i* is null.
    internal var validity: BitVector
    /// The fixed dimensionality of every vector in this array.
    public let dims: Int
    /// Per-row cached squared L2 norm (`dotF(v, v)`); 0 for null rows.
    internal var squaredNorms: NativeArray<Float>

    // MARK: - Properties

    /// The number of rows (including null rows).
    public var count: Int { validity.bitCount }

    /// The number of non-null rows.
    public var validCount: Int { validity.popcount }

    /// Total memory usage: plane + validity bitmap words + norm cache.
    public var nbytes: Int {
        plane.nbytes + validity.words.count * MemoryLayout<UInt64>.stride + squaredNorms.nbytes
    }

    // MARK: - Construction

    /// Create from optional vectors; `nil` elements become null rows
    /// (bitmap-cleared, zero-filled plane slot).
    ///
    /// - Throws: ``VectorError/invalidArgument(_:)`` if `dims < 1`;
    ///   ``VectorError/dimensionMismatch(expected:got:)`` if any element's
    ///   count differs from `dims`.
    public init(vectors: [[Float]?], dims: Int) throws {
        guard dims >= 1 else {
            throw VectorError.invalidArgument("dims must be >= 1, got \(dims)")
        }
        var flat = ContiguousArray<Float>()
        flat.reserveCapacity(vectors.count * dims)
        var valid = [Bool]()
        valid.reserveCapacity(vectors.count)
        for vector in vectors {
            if let vector = vector {
                guard vector.count == dims else {
                    throw VectorError.dimensionMismatch(expected: dims, got: vector.count)
                }
                flat.append(contentsOf: vector)
                valid.append(true)
            } else {
                flat.append(contentsOf: repeatElement(0, count: dims))
                valid.append(false)
            }
        }
        self.init(plane: NativeArray(flat), validity: BitVector(valid), dims: dims)
    }

    /// Create from dense vectors (no nulls).
    public init(vectors: [[Float]], dims: Int) throws {
        guard dims >= 1 else {
            throw VectorError.invalidArgument("dims must be >= 1, got \(dims)")
        }
        var flat = ContiguousArray<Float>()
        flat.reserveCapacity(vectors.count * dims)
        for vector in vectors {
            guard vector.count == dims else {
                throw VectorError.dimensionMismatch(expected: dims, got: vector.count)
            }
            flat.append(contentsOf: vector)
        }
        self.init(
            plane: NativeArray(flat),
            validity: BitVector(repeating: true, count: vectors.count),
            dims: dims)
    }

    /// Internal init from pre-validated storage; computes the norm cache.
    /// Callers must guarantee the invariants (dims >= 1, zero-filled nulls,
    /// consistent lengths).
    internal init(plane: NativeArray<Float>, validity: BitVector, dims: Int) {
        precondition(dims >= 1, "VectorArray dims must be >= 1")
        precondition(plane.count == validity.bitCount * dims,
                     "VectorArray plane length \(plane.count) != rows \(validity.bitCount) * dims \(dims)")
        self.plane = plane
        self.validity = validity
        self.dims = dims
        self.squaredNorms = Self.computeSquaredNorms(plane: plane, dims: dims)
    }

    /// Internal init that carries a pre-sliced norm cache (take/copy paths).
    internal init(
        plane: NativeArray<Float>, validity: BitVector, dims: Int,
        squaredNorms: NativeArray<Float>
    ) {
        precondition(plane.count == validity.bitCount * dims)
        precondition(squaredNorms.count == validity.bitCount)
        self.plane = plane
        self.validity = validity
        self.dims = dims
        self.squaredNorms = squaredNorms
    }

    private static func computeSquaredNorms(plane: NativeArray<Float>, dims: Int) -> NativeArray<Float> {
        let rows = plane.count / Swift.max(dims, 1)
        guard rows > 0 else { return NativeArray(ContiguousArray<Float>()) }
        var norms = ContiguousArray<Float>(repeating: 0, count: rows)
        plane.withUnsafeBufferPointer { src in
            norms.withUnsafeMutableBufferPointer { dst in
                for row in 0..<rows {
                    let slice = UnsafeBufferPointer(rebasing: src[(row * dims)..<((row + 1) * dims)])
                    dst[row] = VectorOps.dotF(slice, slice)
                }
            }
        }
        return NativeArray(norms)
    }

    // MARK: - Row access

    /// The vector at `row`, or `nil` for a null row. Copies.
    public func row(_ index: Int) -> [Float]? {
        precondition(index >= 0 && index < count, "Index \(index) out of range")
        guard validity[index] else { return nil }
        return plane.withUnsafeBufferPointer { src in
            Array(src[(index * dims)..<((index + 1) * dims)])
        }
    }

    /// NA mask: `true` at position *i* means row *i* is null.
    public func isNA() -> [Bool] {
        validity.boolArray.map { !$0 }
    }

    // MARK: - Take / copy / concat

    /// Gather rows at the given positions. Out-of-range or negative indices
    /// produce null rows, matching the other Column storage types.
    public func take(indices: [Int]) -> VectorArray {
        let n = count
        var flat = ContiguousArray<Float>(repeating: 0, count: indices.count * dims)
        var norms = ContiguousArray<Float>(repeating: 0, count: indices.count)
        var valid = [Bool](repeating: false, count: indices.count)
        plane.withUnsafeBufferPointer { src in
            squaredNorms.withUnsafeBufferPointer { srcNorms in
                flat.withUnsafeMutableBufferPointer { dst in
                    for (j, i) in indices.enumerated() where i >= 0 && i < n && validity[i] {
                        let s = i * dims
                        let d = j * dims
                        for k in 0..<dims { dst[d + k] = src[s + k] }
                        norms[j] = srcNorms[i]
                        valid[j] = true
                    }
                }
            }
        }
        return VectorArray(
            plane: NativeArray(flat), validity: BitVector(valid), dims: dims,
            squaredNorms: NativeArray(norms))
    }

    /// Gather rows where `mask` is true. `trueCount` must equal the number of
    /// true entries (same contract as the other storage types).
    public func take(mask: [Bool], trueCount: Int) -> VectorArray {
        precondition(mask.count == count, "Mask length \(mask.count) != row count \(count)")
        var flat = ContiguousArray<Float>(repeating: 0, count: trueCount * dims)
        var norms = ContiguousArray<Float>(repeating: 0, count: trueCount)
        var valid = [Bool](repeating: false, count: trueCount)
        plane.withUnsafeBufferPointer { src in
            squaredNorms.withUnsafeBufferPointer { srcNorms in
                flat.withUnsafeMutableBufferPointer { dst in
                    var j = 0
                    for i in 0..<mask.count where mask[i] {
                        if validity[i] {
                            let s = i * dims
                            let d = j * dims
                            for k in 0..<dims { dst[d + k] = src[s + k] }
                            norms[j] = srcNorms[i]
                            valid[j] = true
                        }
                        j += 1
                    }
                }
            }
        }
        return VectorArray(
            plane: NativeArray(flat), validity: BitVector(valid), dims: dims,
            squaredNorms: NativeArray(norms))
    }

    /// Deep, independent copy.
    public func copy() -> VectorArray {
        VectorArray(
            plane: NativeArray(ContiguousArray(plane.array)),
            validity: validity,
            dims: dims,
            squaredNorms: NativeArray(ContiguousArray(squaredNorms.array)))
    }

    /// Concatenate arrays end to end.
    ///
    /// - Throws: ``VectorError/dimensionMismatch(expected:got:)`` if the
    ///   arrays do not all share the same `dims`.
    public static func concat(_ arrays: [VectorArray]) throws -> VectorArray {
        guard let first = arrays.first else {
            return VectorArray(plane: NativeArray(ContiguousArray<Float>()),
                               validity: BitVector(repeating: true, count: 0), dims: 1)
        }
        for array in arrays.dropFirst() where array.dims != first.dims {
            throw VectorError.dimensionMismatch(expected: first.dims, got: array.dims)
        }
        var plane = first.plane
        var norms = first.squaredNorms
        var validity = first.validity
        for array in arrays.dropFirst() {
            plane.append(contentsOf: array.plane)
            norms.append(contentsOf: array.squaredNorms)
            validity.append(contentsOf: array.validity)
        }
        return VectorArray(plane: plane, validity: validity, dims: first.dims, squaredNorms: norms)
    }
}
