/// Array type specialized for String values with NA support.
///
/// Backed by [String?] since strings are variable-length and can't be
/// stored in a fixed-stride NativeArray. Uses Optional to represent NA.
public struct StringArray {
    internal var storage: [String?]

    // MARK: - Initializers

    /// Create from an array of optional strings.
    public init(_ elements: [String?]) {
        self.storage = elements
    }

    /// Create from an array of non-optional strings (no NAs).
    public init(_ elements: [String]) {
        self.storage = elements.map { $0 as String? }
    }

    /// Create an empty StringArray.
    public init() {
        self.storage = []
    }

    // MARK: - Access

    public var count: Int { storage.count }

    public var isEmpty: Bool { storage.isEmpty }

    public var nbytes: Int {
        storage.reduce(0) { $0 + ($1?.utf8.count ?? 0) }
    }

    public var validCount: Int {
        storage.count { $0 != nil }
    }

    public var naCount: Int {
        count - validCount
    }

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

    /// Boolean mask: true where value is NA.
    public func isNA() -> [Bool] {
        storage.map { $0 == nil }
    }

    // MARK: - Operations

    public func copy() -> StringArray {
        StringArray(storage)
    }

    public func take(indices: [Int]) -> StringArray {
        StringArray(indices.map { i in
            (i >= 0 && i < count) ? storage[i] : nil
        })
    }

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

    public func factorize() -> (codes: [Int], uniques: StringArray) {
        var mapping = [String: Int]()
        var uniques = [String?]()
        var codes = [Int]()
        codes.reserveCapacity(count)

        for s in storage {
            if let s = s {
                if let code = mapping[s] {
                    codes.append(code)
                } else {
                    let code = uniques.count
                    mapping[s] = code
                    uniques.append(s)
                    codes.append(code)
                }
            } else {
                codes.append(-1)
            }
        }
        return (codes, StringArray(uniques))
    }

    public func fillNA(value: String) -> StringArray {
        StringArray(storage.map { $0 ?? value })
    }

    public func dropNA() -> [String] {
        storage.compactMap { $0 }
    }

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

extension StringArray: Equatable {}

// MARK: - Sendable

extension StringArray: Sendable {}
