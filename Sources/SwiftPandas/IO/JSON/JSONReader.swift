// MARK: - JSONReader.swift
//
// JSON I/O for SwiftPandas DataFrames. Supports reading JSON arrays-of-objects
// ("records" orientation) into DataFrames, and writing DataFrames back to JSON.

import Foundation

/// Reads JSON data into a ``DataFrame``.
///
/// Supports the "records" orientation: a JSON array of objects where each object
/// represents a row and keys are column names.
///
/// ```json
/// [
///   {"name": "Alice", "age": 30},
///   {"name": "Bob",   "age": 25}
/// ]
/// ```
public struct JSONReader {
    public init() {}

    /// Parses a JSON string in records orientation into a ``DataFrame``.
    public func read(from jsonString: String) throws -> DataFrame {
        guard let data = jsonString.data(using: .utf8) else {
            throw DataFrameError.invalidJSON("Could not encode string as UTF-8")
        }
        return try read(from: data)
    }

    /// Parses JSON `Data` in records orientation into a ``DataFrame``.
    public func read(from data: Data) throws -> DataFrame {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DataFrameError.invalidJSON(error.localizedDescription)
        }

        guard let records = parsed as? [[String: Any]] else {
            throw DataFrameError.invalidJSON("Expected an array of objects")
        }

        guard !records.isEmpty else {
            return DataFrame()
        }

        // Collect all keys preserving first-seen order
        var seenKeys = Set<String>()
        var orderedKeys = [String]()
        for record in records {
            for key in record.keys.sorted() {
                if seenKeys.insert(key).inserted {
                    orderedKeys.append(key)
                }
            }
        }

        // Determine column types and build columns
        var resultColumns = [(String, Column)]()
        for key in orderedKeys {
            // Check if all non-nil values are numeric
            var allNumeric = true
            var allBool = true
            for record in records {
                guard let val = record[key] else { continue }
                if val is NSNull { continue }
                if !(val is NSNumber) && !(val is Int) && !(val is Double) {
                    allNumeric = false
                }
                if !(val is Bool) {
                    allBool = false
                }
            }

            if allBool && !allNumeric {
                // Bool column
                let values: [Bool?] = records.map { record in
                    guard let val = record[key] else { return nil }
                    if val is NSNull { return nil }
                    return val as? Bool
                }
                resultColumns.append((key, Column.fromOptionalBools(values)))
            } else if allNumeric {
                // Double column
                let values: [Double?] = records.map { record in
                    guard let val = record[key] else { return nil }
                    if val is NSNull { return nil }
                    if let d = val as? Double { return d }
                    if let i = val as? Int { return Double(i) }
                    if let n = val as? NSNumber { return n.doubleValue }
                    return nil
                }
                resultColumns.append((key, .fromOptionalDoubles(values)))
            } else {
                // String column
                let values: [String?] = records.map { record in
                    guard let val = record[key] else { return nil }
                    if val is NSNull { return nil }
                    if let s = val as? String { return s }
                    return "\(val)"
                }
                resultColumns.append((key, .fromOptionalStrings(values)))
            }
        }

        return DataFrame(columns: resultColumns)
    }
}

/// Writes a ``DataFrame`` to JSON format.
public struct JSONWriter {
    public init() {}

    /// Serializes the DataFrame to a JSON string in records orientation.
    public func write(_ df: DataFrame) -> String {
        var records = [[String: Any]]()
        records.reserveCapacity(df.rowCount)

        for i in 0..<df.rowCount {
            var row = [String: Any]()
            for name in df.columnNames {
                if let col = df.columns[name] {
                    if let val = col.value(at: i) {
                        row[name] = val
                    } else {
                        row[name] = NSNull()
                    }
                }
            }
            records.append(row)
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: records,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return "[]"
        }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

// MARK: - DataFrame Convenience Methods

extension DataFrame {
    /// Creates a ``DataFrame`` by parsing a JSON string in records orientation.
    public static func readJSON(_ jsonString: String) throws -> DataFrame {
        try JSONReader().read(from: jsonString)
    }

    /// Creates a ``DataFrame`` by parsing JSON `Data` in records orientation.
    public static func readJSON(data: Data) throws -> DataFrame {
        try JSONReader().read(from: data)
    }

    /// Creates a ``DataFrame`` by reading a JSON file at the given path.
    public static func readJSON(path: String) throws -> DataFrame {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONReader().read(from: data)
    }

    /// Creates a ``DataFrame`` by reading a JSON file at the given URL.
    public static func readJSON(url: URL) throws -> DataFrame {
        let data = try Data(contentsOf: url)
        return try JSONReader().read(from: data)
    }

    /// Serializes this ``DataFrame`` to a JSON string in records orientation.
    public func toJSON() -> String {
        JSONWriter().write(self)
    }

    /// Writes this ``DataFrame`` to a JSON file at the given path.
    public func toJSON(path: String) throws {
        let json = toJSON()
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Writes this ``DataFrame`` to a JSON file at the given URL.
    public func toJSON(url: URL) throws {
        let json = toJSON()
        try json.write(to: url, atomically: true, encoding: .utf8)
    }
}
