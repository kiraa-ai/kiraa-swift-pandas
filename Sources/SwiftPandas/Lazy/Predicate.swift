/// Column reference for building inspectable predicates.
///
/// Use `col("name")` to create a column reference, then chain comparison operators:
/// ```swift
/// col("revenue") > 1000
/// col("name").contains("Inc")
/// ```
public struct Col {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// Shorthand for creating a column reference.
public func col(_ name: String) -> Col {
    Col(name)
}

/// Comparison operations for predicates.
public enum CompOp: Sendable, Equatable {
    case eq, ne, gt, ge, lt, le
}

/// Literal values that can appear in predicates.
public enum PredicateValue: Sendable, Equatable {
    case double(Double)
    case string(String)
    case int64(Int64)
    case bool(Bool)
}

/// Inspectable predicate expression tree.
///
/// Unlike opaque closures, predicates can be analyzed and transformed by
/// the query optimizer — enabling filter fusion and predicate pushdown.
public indirect enum ColumnPredicate: Sendable {
    case comparison(column: String, op: CompOp, value: PredicateValue)
    case and(ColumnPredicate, ColumnPredicate)
    case or(ColumnPredicate, ColumnPredicate)
    case not(ColumnPredicate)
    case stringContains(column: String, substring: String)

    // MARK: - Analysis

    /// All column names referenced by this predicate.
    public var referencedColumns: Set<String> {
        switch self {
        case .comparison(let column, _, _):
            return [column]
        case .stringContains(let column, _):
            return [column]
        case .and(let lhs, let rhs), .or(let lhs, let rhs):
            return lhs.referencedColumns.union(rhs.referencedColumns)
        case .not(let inner):
            return inner.referencedColumns
        }
    }

    // MARK: - Evaluation

    /// Evaluate this predicate against a DataFrame, returning a boolean mask.
    ///
    /// Dispatches to the existing Series comparison operators so we don't
    /// reimplement comparison logic.
    public func evaluate(on df: DataFrame) -> [Bool] {
        switch self {
        case .comparison(let column, let op, let value):
            let series = df[column]
            switch value {
            case .double(let v):
                switch op {
                case .gt: return series > v
                case .ge: return series >= v
                case .lt: return series < v
                case .le: return series <= v
                case .eq: return series.eq(v)
                case .ne: return series.ne(v)
                }
            case .string(let v):
                switch op {
                case .eq: return series.eq(v)
                case .ne: return series.ne(v)
                default:
                    // String columns only support eq/ne
                    return [Bool](repeating: false, count: df.rowCount)
                }
            case .int64(let v):
                // Promote to Double for comparison
                let d = Double(v)
                switch op {
                case .gt: return series > d
                case .ge: return series >= d
                case .lt: return series < d
                case .le: return series <= d
                case .eq: return series.eq(d)
                case .ne: return series.ne(d)
                }
            case .bool:
                return [Bool](repeating: false, count: df.rowCount)
            }

        case .stringContains(let column, let substring):
            let series = df[column]
            return series.strContains(substring)

        case .and(let lhs, let rhs):
            let l = lhs.evaluate(on: df)
            let r = rhs.evaluate(on: df)
            return zip(l, r).map { $0 && $1 }

        case .or(let lhs, let rhs):
            let l = lhs.evaluate(on: df)
            let r = rhs.evaluate(on: df)
            return zip(l, r).map { $0 || $1 }

        case .not(let inner):
            return inner.evaluate(on: df).map { !$0 }
        }
    }
}

// MARK: - Col operator overloads → Predicate

// Double comparisons
public func > (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .gt, value: .double(rhs))
}
public func >= (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ge, value: .double(rhs))
}
public func < (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .lt, value: .double(rhs))
}
public func <= (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .le, value: .double(rhs))
}
public func == (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .double(rhs))
}
public func != (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .double(rhs))
}

// Int comparisons (promote to Int64)
public func > (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .gt, value: .int64(Int64(rhs)))
}
public func >= (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ge, value: .int64(Int64(rhs)))
}
public func < (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .lt, value: .int64(Int64(rhs)))
}
public func <= (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .le, value: .int64(Int64(rhs)))
}
public func == (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .int64(Int64(rhs)))
}
public func != (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .int64(Int64(rhs)))
}

// String equality
public func == (lhs: Col, rhs: String) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .string(rhs))
}
public func != (lhs: Col, rhs: String) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .string(rhs))
}

// Col.contains for string substring matching
extension Col {
    public func contains(_ substring: String) -> ColumnPredicate {
        .stringContains(column: name, substring: substring)
    }
}

// Predicate combinators
public func & (lhs: ColumnPredicate, rhs: ColumnPredicate) -> ColumnPredicate {
    .and(lhs, rhs)
}
public func | (lhs: ColumnPredicate, rhs: ColumnPredicate) -> ColumnPredicate {
    .or(lhs, rhs)
}
public prefix func ! (pred: ColumnPredicate) -> ColumnPredicate {
    .not(pred)
}

// MARK: - CustomStringConvertible

extension ColumnPredicate: CustomStringConvertible {
    public var description: String {
        switch self {
        case .comparison(let col, let op, let val):
            let opStr: String
            switch op {
            case .eq: opStr = "=="
            case .ne: opStr = "!="
            case .gt: opStr = ">"
            case .ge: opStr = ">="
            case .lt: opStr = "<"
            case .le: opStr = "<="
            }
            return "\(col) \(opStr) \(val)"
        case .and(let l, let r):
            return "(\(l) AND \(r))"
        case .or(let l, let r):
            return "(\(l) OR \(r))"
        case .not(let inner):
            return "NOT(\(inner))"
        case .stringContains(let col, let sub):
            return "\(col).contains(\"\(sub)\")"
        }
    }
}

extension PredicateValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .double(let v): return "\(v)"
        case .string(let v): return "\"\(v)\""
        case .int64(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        }
    }
}
