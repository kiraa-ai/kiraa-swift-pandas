// ===----------------------------------------------------------------------===//
//
// VectorSeriesOps.swift
// SwiftPandas
//
// Distance metrics and Series-level vector operations (norms, normalization)
// for `.floatVector` columns.
//
// Storage invariant (cross-module, normative): a ``VectorArray`` always holds
// **raw** vectors. Normalization is only ever an explicit, new-value operation
// (``Series/normalizedL2()``) — never applied implicitly by construction, IO,
// or search. This is the premise of the search bit-parity contract: all three
// metrics score from one raw plane.
//
// ===----------------------------------------------------------------------===//

/// The similarity/distance metric used by ``DataFrame/similaritySearch(on:query:options:)``.
public enum DistanceMetric: String, Sendable, Codable, CaseIterable {
    /// Cosine similarity: `dot / (|a||b|)`. Higher is better; range [-1, 1];
    /// defined as 0 when either norm is 0.
    case cosine
    /// Dot product. Higher is better.
    case dot
    /// Euclidean (L2) distance. **Lower** is better.
    case euclidean
}

// MARK: - Series construction & access

public extension Series {
    /// Create a Series backed by a `.floatVector` column.
    ///
    /// - Throws: ``VectorError/dimensionMismatch(expected:got:)`` /
    ///   ``VectorError/invalidArgument(_:)`` per ``Column/fromVectors(_:dims:)``.
    init(vectors: [[Float]], dims: Int, name: String) throws {
        self.init(data: try .fromVectors(vectors, dims: dims), name: name)
    }
}

extension Series {
    /// The dimensionality of this series' vectors, or `nil` for non-vector
    /// series. This is the safe probe for "is this a vector series?".
    public var vectorDims: Int? {
        if case .floatVector(let a) = data { return a.dims }
        return nil
    }

    private func requireVectorArray(op: String) -> VectorArray {
        guard case .floatVector(let a) = data else {
            preconditionFailure(
                "\(op) is only valid on floatVector series (got \(data.dtype)); "
                + "probe with vectorDims first")
        }
        return a
    }

    /// The vector at `row`, or `nil` for a null row. Copies.
    ///
    /// Only valid on floatVector series (precondition failure otherwise —
    /// this non-throwing accessor mirrors the subscript conventions of the
    /// library; use ``vectorDims`` to probe).
    public func vector(at row: Int) -> [Float]? {
        requireVectorArray(op: "vector(at:)").row(row)
    }

    /// All vectors, null rows as `nil`. Copies.
    public func vectors() -> [[Float]?] {
        let array = requireVectorArray(op: "vectors()")
        return (0..<array.count).map { array.row($0) }
    }

    /// Zero-copy access to the raw row-major plane for compute kernels. The
    /// body receives the full plane (`count * dims` floats) and the dims; no
    /// copy is allocated.
    public func withUnsafeVectorPlane<R>(
        _ body: (UnsafeBufferPointer<Float>, _ dims: Int) throws -> R
    ) rethrows -> R {
        let array = requireVectorArray(op: "withUnsafeVectorPlane")
        return try array.plane.withUnsafeBufferPointer { try body($0, array.dims) }
    }

    /// Per-row L2 norms (`sqrt` of the construction-time cached squared
    /// norms); null rows report 0.
    ///
    /// - Throws: ``VectorError/unsupportedOperation(op:dtype:)`` on
    ///   non-vector series.
    public func l2Norms() throws -> [Float] {
        guard case .floatVector(let array) = data else {
            throw VectorError.unsupportedOperation(op: "l2Norms", dtype: data.dtype.description)
        }
        return array.squaredNorms.withUnsafeBufferPointer { norms in
            norms.map { $0.squareRoot() }
        }
    }

    /// A new series whose vectors are L2-normalized (unit length). Zero-norm
    /// rows stay zero vectors; null rows stay null.
    ///
    /// This is the **only** normalizer in the library — storage always holds
    /// raw vectors, and construction/IO/search never normalize implicitly.
    ///
    /// - Throws: ``VectorError/unsupportedOperation(op:dtype:)`` on
    ///   non-vector series.
    public func normalizedL2() throws -> Series {
        guard case .floatVector(let array) = data else {
            throw VectorError.unsupportedOperation(op: "normalizedL2", dtype: data.dtype.description)
        }
        let dims = array.dims
        var normalized = ContiguousArray<Float>(repeating: 0, count: array.plane.count)
        array.plane.withUnsafeBufferPointer { src in
            array.squaredNorms.withUnsafeBufferPointer { norms in
                normalized.withUnsafeMutableBufferPointer { dst in
                    for row in 0..<array.count {
                        let norm = norms[row].squareRoot()
                        guard norm != 0 else { continue }  // zero vectors (and nulls) stay zero
                        let base = row * dims
                        for k in 0..<dims { dst[base + k] = src[base + k] / norm }
                    }
                }
            }
        }
        let result = VectorArray(
            plane: NativeArray(normalized), validity: array.validity, dims: dims)
        return Series(data: .floatVector(result), name: name)
    }
}
