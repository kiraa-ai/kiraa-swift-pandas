// MARK: - DataFrameError.swift
//
// Public error type for recoverable errors in DataFrame and Series operations.

import Foundation

/// Errors thrown by DataFrame and Series operations.
///
/// Use the throwing API variants (e.g., ``DataFrame/column(_:)``,
/// ``DataFrame/mergeThrowing(_:on:how:)``) to receive these errors instead
/// of the default `fatalError` behavior of the subscript-based API.
public enum DataFrameError: Error, CustomStringConvertible, Sendable {
    /// The requested column name does not exist in the DataFrame.
    case columnNotFound(String)

    /// A type mismatch occurred (e.g., expected numeric column, got string).
    case typeMismatch(expected: String, got: String)

    /// Array lengths do not match (e.g., mask length vs row count).
    case lengthMismatch(expected: Int, got: Int)

    /// A positional index is out of the valid range.
    case indexOutOfRange(position: Int, count: Int)

    /// A key column required for merge/join was not found in one or both DataFrames.
    case keyColumnNotFound(String)

    /// JSON data could not be parsed into a DataFrame.
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .columnNotFound(let name):
            return "Column '\(name)' not found"
        case .typeMismatch(let expected, let got):
            return "Type mismatch: expected \(expected), got \(got)"
        case .lengthMismatch(let expected, let got):
            return "Length mismatch: expected \(expected) rows, got \(got)"
        case .indexOutOfRange(let pos, let count):
            return "Index \(pos) out of range [0, \(count))"
        case .keyColumnNotFound(let key):
            return "Key column '\(key)' not found in both DataFrames"
        case .invalidJSON(let detail):
            return "Invalid JSON: \(detail)"
        }
    }
}
