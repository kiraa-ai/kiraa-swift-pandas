// ===----------------------------------------------------------------------===//
//
// VectorError.swift
// SwiftPandas
//
// Typed errors for the vector column type, similarity search, and SPB binary
// IO. Every misuse of the vector API throws one of these cases with a
// human-readable description — nothing returns an empty result on invalid
// input.
//
// Boundary with ``DataFrameError``: frame-shape problems (e.g. a missing
// column name passed to `similaritySearch(on:)`) keep throwing
// ``DataFrameError`` for consistency with every other column-resolving API;
// vector-semantics problems throw ``VectorError``.
//
// ===----------------------------------------------------------------===//

/// Errors thrown by vector column construction, similarity search, and SPB IO.
public enum VectorError: Error, CustomStringConvertible, Sendable {
    /// A vector's element count does not match the required dimensionality.
    case dimensionMismatch(expected: Int, got: Int)
    /// A candidate mask's length does not match the frame's row count.
    case maskLengthMismatch(expected: Int, got: Int)
    /// The requested operation is not supported for the given dtype.
    case unsupportedOperation(op: String, dtype: String)
    /// The `.metal` backend was requested but the device/pipeline is unusable.
    case metalUnavailable(String)
    /// The `.metal` backend was requested with a metric the GPU does not
    /// support (GPU is cosine-only in v1).
    case metalUnsupportedMetric(DistanceMetric)
    /// An SPB file failed validation. The reason is human-readable.
    case corrupt(reason: String)
    /// An SPB file declares a format version newer than this library supports.
    case versionUnsupported(found: UInt32, supported: UInt32)
    /// A caller-supplied argument is invalid (topK <= 0, dims < 1, empty
    /// query, ...).
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .dimensionMismatch(let expected, let got):
            return "dimension mismatch: expected \(expected), got \(got)"
        case .maskLengthMismatch(let expected, let got):
            return "mask length mismatch: expected \(expected) (row count), got \(got)"
        case .unsupportedOperation(let op, let dtype):
            return "unsupported operation '\(op)' for dtype \(dtype)"
        case .metalUnavailable(let reason):
            return "Metal backend unavailable: \(reason)"
        case .metalUnsupportedMetric(let metric):
            return "Metal backend does not support metric '\(metric.rawValue)' (cosine only)"
        case .corrupt(let reason):
            return "corrupt SPB data: \(reason)"
        case .versionUnsupported(let found, let supported):
            return "unsupported SPB format version \(found) (this library supports <= \(supported))"
        case .invalidArgument(let reason):
            return "invalid argument: \(reason)"
        }
    }
}
