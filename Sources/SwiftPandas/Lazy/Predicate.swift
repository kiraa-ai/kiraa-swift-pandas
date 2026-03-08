// MARK: - Predicate.swift
//
// This file defines the **predicate expression tree** used by SwiftPandas's lazy
// evaluation engine to represent row-level filter conditions.
//
// ## Why an Expression Tree Instead of Closures?
//
// A naive lazy-filter API would accept a Swift closure `(Row) -> Bool`. While easy
// to implement, closures are **opaque** — the optimizer cannot inspect their contents,
// determine which columns they reference, or restructure them. This makes several
// important optimizations impossible:
//
// - **Filter fusion**: merging `filter(p1).filter(p2)` into `filter(p1 AND p2)` is
//   trivial with expression trees (just wrap both in a `.and` node) but impossible
//   with closures (you would need to compose two `(Row) -> Bool` at runtime with
//   no ability to simplify).
// - **Predicate pushdown**: moving a filter below a sort or group-by requires
//   knowing which columns the predicate references, so the optimizer can verify
//   those columns exist in the source. Closures carry no such metadata.
// - **Projection pushdown**: knowing the predicate's referenced columns lets the
//   optimizer widen a projection to include them before pushing the projection
//   down, and narrow it afterward.
// - **Join filter routing**: when a filter sits above a join, the optimizer can
//   route it into the left or right branch based on which side's columns the
//   predicate references — only possible with column visibility.
//
// ## Components
//
// - `Col` — A lightweight reference to a named column. Created via the free function
//   `col(_:)`. Operator overloads on `Col` produce `ColumnPredicate` values, giving
//   users a natural DSL: `col("price") > 9.99`.
//
// - `CompOp` — The six standard comparison operators (`==`, `!=`, `>`, `>=`, `<`,
//   `<=`), stored as an enum so the evaluator can dispatch without closures.
//
// - `PredicateValue` — A type-erased literal value (Double, String, Int64, Bool)
//   that appears on the right-hand side of a comparison. Wrapping literals in an
//   enum keeps the predicate tree homogeneous and `Sendable`.
//
// - `ColumnPredicate` — The recursive expression tree itself. It is an `indirect
//   enum` with cases for comparisons, boolean combinators (`AND`, `OR`, `NOT`),
//   and string-contains checks. The tree is fully inspectable: the optimizer can
//   pattern-match on it, the evaluator can walk it, and `referencedColumns`
//   computes the set of column names it touches.
//
// ## Evaluation
//
// `ColumnPredicate.evaluate(on:)` takes a concrete `DataFrame` and returns a
// `[Bool]` mask of length `rowCount`. It delegates to the existing `Series`
// comparison operators (which may themselves use Accelerate / vDSP), so no
// comparison logic is duplicated.
//
// ## Operator Overloads & Combinators
//
// Free-function operator overloads (`>`, `>=`, `<`, `<=`, `==`, `!=`) on `Col`
// with `Double`, `Int`, and `String` right-hand sides produce `ColumnPredicate`
// values. The bitwise operators `&` (AND), `|` (OR), and prefix `!` (NOT) combine
// predicates. These use bitwise operator symbols rather than `&&`/`||` because Swift
// does not allow overloading short-circuit logical operators on custom types.
//
// ## Thread Safety
//
// `ColumnPredicate` conforms to `Sendable`. Since it is a recursive enum of value
// types, it is inherently safe to share across isolation boundaries.
//
// ## Key Algorithms
//
// - **Referenced-column extraction** (`referencedColumns`): recursively collects
//   the set of column names that appear anywhere in the expression tree. The
//   query optimizer uses this to decide whether a predicate can be pushed below
//   a projection, sort, or group-by node.
//
// - **Boolean mask evaluation** (`evaluate(on:)`): walks the tree bottom-up,
//   evaluating leaf comparisons against the DataFrame's Series data and combining
//   results with element-wise `&&`, `||`, and `!` for logical nodes.

// MARK: - Col (Column Reference)

/// A lightweight, named reference to a single DataFrame column.
///
/// `Col` exists solely to serve as the left-hand operand in predicate expressions.
/// It carries only the column name and has no connection to any particular DataFrame —
/// the name is resolved at evaluation time by ``ColumnPredicate/evaluate(on:)``.
///
/// You rarely construct `Col` directly; use the ``col(_:)`` free function instead:
///
/// ```swift
/// col("revenue") > 1000          // ColumnPredicate.comparison(...)
/// col("name").contains("Inc")    // ColumnPredicate.stringContains(...)
/// ```
///
/// ## Operator Overloads
///
/// `Col` participates in the following operator families, each of which returns a
/// ``ColumnPredicate``:
///
/// | Operator | RHS Types           | Resulting `CompOp` |
/// |----------|---------------------|--------------------|
/// | `>`      | Double, Int         | `.gt`              |
/// | `>=`     | Double, Int         | `.ge`              |
/// | `<`      | Double, Int         | `.lt`              |
/// | `<=`     | Double, Int         | `.le`              |
/// | `==`     | Double, Int, String | `.eq`              |
/// | `!=`     | Double, Int, String | `.ne`              |
///
/// Additionally, the ``contains(_:)`` method produces a `.stringContains` predicate
/// for substring matching on string columns.
public struct Col {
    /// The name of the DataFrame column this reference points to.
    public let name: String

    /// Creates a column reference for the given column name.
    ///
    /// - Parameter name: The exact DataFrame column name as it appears in the
    ///   DataFrame's `columnNames` array. The name is not validated at construction
    ///   time; an invalid name will produce unexpected results at evaluation time.
    public init(_ name: String) { self.name = name }
}

/// Factory function that creates a ``Col`` column reference.
///
/// This is the recommended (and most concise) way to begin building a predicate
/// expression. The short name keeps filter expressions readable and closely mirrors
/// SQL column references:
///
/// ```swift
/// df.lazy().filter(col("age") >= 18 & col("active") == 1)
/// ```
///
/// - Parameter name: The DataFrame column name to reference.
/// - Returns: A ``Col`` instance wrapping the given name.
public func col(_ name: String) -> Col {
    Col(name)
}

// MARK: - CompOp (Comparison Operator)

/// Comparison operations that can appear in a ``ColumnPredicate``.
///
/// Each case maps to a standard relational operator. The optimizer treats these
/// as opaque tags -- it does not attempt to invert or simplify comparisons, but
/// it does preserve them faithfully through predicate pushdown and filter fusion.
public enum CompOp: Sendable, Equatable {
    /// Equal (`==`).
    case eq
    /// Not equal (`!=`).
    case ne
    /// Greater than (`>`).
    case gt
    /// Greater than or equal (`>=`).
    case ge
    /// Less than (`<`).
    case lt
    /// Less than or equal (`<=`).
    case le
}

// MARK: - PredicateValue (Literal Value)

/// A type-erased literal value that can appear on the right-hand side of a
/// column comparison predicate.
///
/// Wrapping literals in an enum serves two purposes:
///
/// 1. It keeps the ``ColumnPredicate`` tree homogeneous — every comparison node
///    stores a `(String, CompOp, PredicateValue)` triple regardless of the
///    literal's concrete Swift type.
/// 2. It preserves `Sendable` conformance, since all payloads are value types.
///
/// ## Type Promotion During Evaluation
///
/// - `.int64` values are promoted to `Double` before comparison so they can be
///   evaluated against ``Series`` numeric comparison operators that operate on
///   `Double` arrays internally.
/// - `.string` values only support `.eq` and `.ne`; ordering comparisons (`>`,
///   `<`, etc.) on string columns produce an all-`false` mask because string
///   ordering is not currently implemented.
/// - `.bool` values are currently unsupported for comparison and produce an
///   all-`false` mask. This case exists for future extensibility.
public enum PredicateValue: Sendable, Equatable {
    /// A 64-bit floating-point literal (e.g., `3.14`, `1000.0`).
    case double(Double)
    /// A string literal (e.g., `"USD"`, `"active"`). Used for equality checks
    /// and substring matching. Ordering comparisons are not supported.
    case string(String)
    /// A 64-bit signed integer literal (e.g., `42`, `-1`). Promoted to `Double`
    /// at evaluation time to match SwiftPandas's internal numeric representation.
    case int64(Int64)
    /// A boolean literal (`true` or `false`). Reserved for future use; currently
    /// evaluates to an all-`false` mask in comparisons.
    case bool(Bool)
}

// MARK: - ColumnPredicate (Expression Tree)

/// An inspectable predicate expression tree for filtering DataFrame rows.
///
/// Unlike opaque closures, `ColumnPredicate` values can be analyzed and
/// transformed by the ``QueryOptimizer`` -- enabling filter fusion (merging
/// consecutive filters into a single `.and` node) and predicate pushdown
/// (moving filters closer to the data source).
///
/// The enum is `indirect` because logical combinators (`.and`, `.or`, `.not`)
/// contain nested `ColumnPredicate` children, forming a recursive tree.
///
/// ## Cases
///
/// | Case | Meaning |
/// |------|---------|
/// | `.comparison` | Scalar comparison of a column against a literal value |
/// | `.stringContains` | Substring search within a string column |
/// | `.and` | Logical conjunction of two predicates |
/// | `.or` | Logical disjunction of two predicates |
/// | `.not` | Logical negation of a predicate |
///
/// ## Example
///
/// ```swift
/// // Built manually:
/// let pred = ColumnPredicate.and(
///     .comparison(column: "age", op: .ge, value: .int64(18)),
///     .comparison(column: "score", op: .gt, value: .double(90.0))
/// )
///
/// // Built with operator sugar (preferred):
/// let pred = col("age") >= 18 & col("score") > 90.0
/// ```
public indirect enum ColumnPredicate: Sendable {
    /// A scalar comparison: `column op value` (e.g., `revenue > 1000.0`).
    case comparison(column: String, op: CompOp, value: PredicateValue)

    /// Logical AND of two predicates. Both must be true for a row to pass.
    case and(ColumnPredicate, ColumnPredicate)

    /// Logical OR of two predicates. At least one must be true for a row to pass.
    case or(ColumnPredicate, ColumnPredicate)

    /// Logical NOT. Inverts the inner predicate's result for every row.
    case not(ColumnPredicate)

    /// Substring containment check on a string column.
    case stringContains(column: String, substring: String)

    // MARK: - Analysis

    /// The set of all column names referenced anywhere in this predicate tree.
    ///
    /// This property is central to several optimizer passes:
    ///
    /// - **Predicate pushdown**: the optimizer checks whether every referenced
    ///   column exists in the source below a sort or group-by before pushing the
    ///   filter down. If the predicate references an aggregated column that only
    ///   exists after grouping, the push is blocked.
    /// - **Projection pushdown**: when a select is pushed below a filter, the
    ///   optimizer widens the select to include all of the predicate's referenced
    ///   columns so they are still available for evaluation.
    /// - **Join filter routing**: the optimizer routes a filter into the left or
    ///   right branch of a join based on which side's columns the predicate
    ///   references.
    ///
    /// The computation is recursive and runs in O(n) time where n is the number of
    /// nodes in the predicate tree:
    ///
    /// - `.comparison` and `.stringContains` return a singleton set of their column.
    /// - `.and` and `.or` return the union of their children's referenced columns.
    /// - `.not` returns its child's referenced columns.
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

    /// Evaluate this predicate against a concrete DataFrame, producing a boolean mask.
    ///
    /// The evaluator walks the expression tree recursively and dispatches each leaf
    /// node to the appropriate ``Series`` comparison method. This design avoids
    /// duplicating comparison logic and automatically benefits from any vectorized
    /// (Accelerate / vDSP) optimizations present in the ``Series`` implementation.
    ///
    /// ## Dispatch Logic by Case
    ///
    /// - **`.comparison`**: Extracts the named column as a ``Series``, then switches
    ///   on the ``PredicateValue`` variant:
    ///   - `.double(v)` — delegates to `Series` operators (`>`, `>=`, `<`, `<=`,
    ///     `.eq()`, `.ne()`) with the Double value directly.
    ///   - `.int64(v)` — promotes `v` to `Double` and then follows the same path
    ///     as `.double`. This is consistent with SwiftPandas's internal numeric
    ///     representation where Series stores Double arrays.
    ///   - `.string(v)` — only `.eq` and `.ne` are supported. Ordering comparisons
    ///     (`>`, `<`, `>=`, `<=`) return an all-`false` mask of length `rowCount`,
    ///     since string ordering is not implemented on Series.
    ///   - `.bool` — currently unsupported; returns an all-`false` mask as a
    ///     placeholder for future boolean-column support.
    ///
    /// - **`.stringContains`**: Calls `Series.strContains(_:)` on the named column,
    ///   returning a mask indicating which rows contain the given substring.
    ///
    /// - **`.and`**: Evaluates both children independently, then produces the
    ///   element-wise conjunction (`&&`) of the two boolean masks using `zip`.
    ///
    /// - **`.or`**: Evaluates both children independently, then produces the
    ///   element-wise disjunction (`||`) of the two boolean masks using `zip`.
    ///
    /// - **`.not`**: Evaluates the single child and negates every element of the
    ///   resulting mask with `map { !$0 }`.
    ///
    /// - Parameter df: The ``DataFrame`` to evaluate the predicate against. The
    ///   DataFrame must contain all columns referenced by the predicate; accessing
    ///   a missing column will trigger the ``DataFrame`` subscript's default
    ///   behavior (typically returning an empty Series).
    /// - Returns: A `[Bool]` array of length `df.rowCount` where `true` indicates
    ///   that the corresponding row satisfies the predicate.
    /// - Complexity: O(*rows* * *leaves*) where *leaves* is the number of leaf nodes
    ///   in the predicate tree. Each leaf triggers a full-column comparison pass.
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

// MARK: - Operator Overloads (Col → ColumnPredicate)
//
// These free-function operator overloads let users write natural comparison
// expressions like `col("price") > 9.99`. Each overload constructs a
// `.comparison` node with the appropriate `CompOp` and `PredicateValue` variant.
//
// Overloads are provided for three right-hand-side types:
//   - `Double`  — stored as `.double`
//   - `Int`     — promoted to `Int64` and stored as `.int64`
//   - `String`  — stored as `.string` (only `==` and `!=`)

// MARK: Double Comparisons

/// Build a "column > double" comparison predicate.
public func > (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .gt, value: .double(rhs))
}
/// Build a "column >= double" comparison predicate.
public func >= (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ge, value: .double(rhs))
}
/// Build a "column < double" comparison predicate.
public func < (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .lt, value: .double(rhs))
}
/// Build a "column <= double" comparison predicate.
public func <= (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .le, value: .double(rhs))
}
/// Build a "column == double" equality predicate.
public func == (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .double(rhs))
}
/// Build a "column != double" inequality predicate.
public func != (lhs: Col, rhs: Double) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .double(rhs))
}

// MARK: Int Comparisons (promoted to Int64 internally)

/// Build a "column > int" comparison predicate. The integer is stored as `Int64`.
public func > (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .gt, value: .int64(Int64(rhs)))
}
/// Build a "column >= int" comparison predicate. The integer is stored as `Int64`.
public func >= (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ge, value: .int64(Int64(rhs)))
}
/// Build a "column < int" comparison predicate. The integer is stored as `Int64`.
public func < (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .lt, value: .int64(Int64(rhs)))
}
/// Build a "column <= int" comparison predicate. The integer is stored as `Int64`.
public func <= (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .le, value: .int64(Int64(rhs)))
}
/// Build a "column == int" equality predicate. The integer is stored as `Int64`.
public func == (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .int64(Int64(rhs)))
}
/// Build a "column != int" inequality predicate. The integer is stored as `Int64`.
public func != (lhs: Col, rhs: Int) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .int64(Int64(rhs)))
}

// MARK: String Equality

/// Build a "column == string" equality predicate.
public func == (lhs: Col, rhs: String) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .eq, value: .string(rhs))
}
/// Build a "column != string" inequality predicate.
public func != (lhs: Col, rhs: String) -> ColumnPredicate {
    .comparison(column: lhs.name, op: .ne, value: .string(rhs))
}

// MARK: String Substring Matching
extension Col {
    /// Build a ``ColumnPredicate/stringContains(column:substring:)`` predicate that
    /// tests whether the column's string values contain the given substring.
    ///
    /// ```swift
    /// col("company").contains("Corp")
    /// ```
    ///
    /// - Parameter substring: The substring to search for within each row's value.
    /// - Returns: A ``ColumnPredicate`` representing the containment check.
    public func contains(_ substring: String) -> ColumnPredicate {
        .stringContains(column: name, substring: substring)
    }
}

// MARK: - Predicate Combinators
//
// The `&`, `|`, and `!` operators combine predicates into compound expression
// trees. These mirror Swift's bitwise operators (not short-circuiting `&&`/`||`)
// to avoid conflicts with the standard library's `Bool` overloads.

/// Combine two predicates with logical AND. A row passes only if **both**
/// sub-predicates evaluate to `true`.
///
/// ```swift
/// col("age") >= 18 & col("active") == 1
/// ```
///
/// - Parameters:
///   - lhs: The left-hand predicate.
///   - rhs: The right-hand predicate.
/// - Returns: A ``ColumnPredicate/and(_:_:)`` node wrapping `lhs` and `rhs`.
public func & (lhs: ColumnPredicate, rhs: ColumnPredicate) -> ColumnPredicate {
    .and(lhs, rhs)
}

/// Combine two predicates with logical OR. A row passes if **either**
/// sub-predicate evaluates to `true`.
///
/// ```swift
/// col("status") == "gold" | col("status") == "platinum"
/// ```
///
/// - Parameters:
///   - lhs: The left-hand predicate.
///   - rhs: The right-hand predicate.
/// - Returns: A ``ColumnPredicate/or(_:_:)`` node wrapping `lhs` and `rhs`.
public func | (lhs: ColumnPredicate, rhs: ColumnPredicate) -> ColumnPredicate {
    .or(lhs, rhs)
}

/// Negate a predicate. Rows that matched the original predicate will be excluded,
/// and rows that did not match will be included.
///
/// ```swift
/// !(col("deleted") == 1)
/// ```
///
/// - Parameter pred: The predicate to negate.
/// - Returns: A ``ColumnPredicate/not(_:)`` node wrapping `pred`.
public prefix func ! (pred: ColumnPredicate) -> ColumnPredicate {
    .not(pred)
}

// MARK: - CustomStringConvertible

/// Human-readable representation of a ``ColumnPredicate`` tree.
///
/// This conformance is used by ``QueryPlan``'s pretty-printer and by
/// ``LazyDataFrame/explain()`` to render filter conditions in plan output.
/// The format is intentionally concise and SQL-like:
///
/// - Comparisons: `column op value` (e.g., `revenue > 1000.0`)
/// - AND: `(lhs AND rhs)` with parentheses for clarity
/// - OR: `(lhs OR rhs)` with parentheses for clarity
/// - NOT: `NOT(inner)`
/// - String contains: `column.contains("substring")`
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

/// Human-readable representation of a ``PredicateValue``.
///
/// String values are wrapped in double quotes to visually distinguish them from
/// numeric values in plan output. Numeric and boolean values use their natural
/// Swift string representation.
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
