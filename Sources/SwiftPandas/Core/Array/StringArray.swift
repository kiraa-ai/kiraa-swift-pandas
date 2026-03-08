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

    /// Take elements where mask is true. `trueCount` must equal mask.filter({$0}).count.
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
        let n = count
        guard n > 0 else { return ([], StringArray()) }

        // Pre-allocate codes array (-1 = NA)
        var codes = [Int](repeating: -1, count: n)
        var uniqueKeys = [String?]()
        uniqueKeys.reserveCapacity(128)

        // Open-addressing hash table with FNV-1a
        var cap = 256
        var mask = cap &- 1
        var table = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        table.initialize(repeating: -1, count: cap)

        // Cache hash values for O(1) resize (avoids re-hashing all unique keys)
        var hashCache = ContiguousArray<Int>()
        hashCache.reserveCapacity(128)

        // Use raw buffer pointer to skip per-element bounds checking
        storage.withUnsafeBufferPointer { storageBuf in
            for i in 0..<n {
                guard let s = storageBuf[i] else { continue }

                // FNV-1a hash
                var h: UInt = 14695981039346656037
                for byte in s.utf8 {
                    h ^= UInt(byte)
                    h &*= 1099511628211
                }
                let hi = Int(bitPattern: h)

                var pos = hi & mask
                while true {
                    let idx = Int(table[pos])
                    if idx < 0 {
                        // New unique key — insert
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
                    if uniqueKeys[idx]! == s {
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
