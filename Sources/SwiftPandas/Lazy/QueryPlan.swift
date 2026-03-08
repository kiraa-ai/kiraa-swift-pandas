// MARK: - QueryPlan.swift
//
// This file defines the logical query plan tree that sits at the heart of the
// lazy evaluation engine.
//
// ## Architecture Overview
//
// A `QueryPlan` is an immutable tree of logical operation nodes. Each node
// describes *what* operation to perform (filter, project, group, sort, join,
// limit) and *which child plan(s)* feed into it. The tree is:
//
//   - **Immutable** — nodes are values of an `indirect enum`, so every
//     transformation produces a new tree rather than mutating in place.
//   - **Sendable** — safe to pass across concurrency domains.
//   - **Inspectable** — the optimizer can pattern-match on node types, examine
//     column references, and rewrite sub-trees without executing anything.
//
// The tree is built top-down by `LazyDataFrame` (each new operation wraps the
// previous plan as its child), then rewritten by `QueryOptimizer`, and finally
// evaluated bottom-up by `QueryExecutor`.
//
// ## Node Kinds
//
// | Node | Arity | Description |
// |------|-------|-------------|
// | `.scan` | 0 (leaf) | References an in-memory DataFrame |
// | `.filter` | 1 | Keeps rows matching a `ColumnPredicate` |
// | `.select` | 1 | Retains only the listed columns (projection) |
// | `.groupBy` | 1 | Groups rows and applies an `AggOp` aggregation |
// | `.sort` | 1 | Orders rows by one or more columns |
// | `.limit` | 1 | Keeps only the first N rows |
// | `.join` | 2 | Combines two plans on a shared key column |
//
// ## Static Analysis Helpers
//
// The plan provides several computed properties that let the optimizer reason
// about structure without executing anything:
//
//   - `children` — direct child plans (0, 1, or 2 elements).
//   - `outputColumns` — the column names this node would produce, if
//     statically determinable. Returns `nil` when the schema cannot be inferred
//     (e.g., after a complex join whose inputs are unknown).
//   - `scanRowCount` / `scanColumnCount` — the dimensions of the deepest
//     `.scan` leaf, useful for `explain()` output.

// MARK: - AggOp

/// Aggregation operations supported by the lazy ``QueryPlan/groupBy(by:agg:_:)`` node.
///
/// Each case maps one-to-one to an eager `GroupBy` method. The ``QueryExecutor``
/// dispatches on this enum to call the corresponding method at execution time.
public enum AggOp: Sendable, Equatable {
    /// Sum of all numeric values in each group.
    case sum
    /// Arithmetic mean of all numeric values in each group.
    case mean
    /// Number of rows in each group.
    case count
    /// Minimum numeric value in each group.
    case min
    /// Maximum numeric value in each group.
    case max
}

// MARK: - QueryPlan

/// A logical query plan node forming an immutable, recursive tree.
///
/// `QueryPlan` is an `indirect enum` so that each case can hold nested
/// `QueryPlan` children, enabling arbitrary-depth plan trees. The tree is
/// constructed by ``LazyDataFrame`` (top-down), rewritten by
/// ``QueryOptimizer`` (pattern-matching rewrites), and evaluated by
/// ``QueryExecutor`` (bottom-up recursive execution).
///
/// Because `QueryPlan` is both a value type and `Sendable`, plan trees can
/// be freely copied, compared, and shared across isolation boundaries.
///
/// ## Example Tree
///
/// ```
/// Limit(10)
///   Sort(revenue DESC)
///     Filter(region == "US")
///       Scan(DataFrame: 50000 rows x 8 cols)
/// ```
public indirect enum QueryPlan: Sendable {
    /// Leaf node: references an in-memory ``DataFrame`` as the data source.
    ///
    /// This is the only node that holds actual data. All other nodes describe
    /// transformations to apply on top of their child plan(s).
    case scan(DataFrame)

    /// Unary node: keeps only the rows for which `predicate` evaluates to `true`.
    ///
    /// - Parameters:
    ///   - predicate: An inspectable ``ColumnPredicate`` expression tree.
    ///   - child: The upstream plan whose output is filtered.
    case filter(ColumnPredicate, QueryPlan)

    /// Unary node: retains only the named columns (projection / column pruning).
    ///
    /// - Parameters:
    ///   - columns: Ordered list of column names to keep.
    ///   - child: The upstream plan whose output is projected.
    case select([String], QueryPlan)

    /// Unary node: groups rows by key columns and applies an aggregation function.
    ///
    /// - Parameters:
    ///   - by: Column names to group by.
    ///   - agg: The aggregation operation to apply to each group.
    ///   - child: The upstream plan whose output is grouped.
    case groupBy(by: [String], agg: AggOp, QueryPlan)

    /// Unary node: sorts rows by one or more columns with per-column direction.
    ///
    /// - Parameters:
    ///   - by: Column names to sort by (earlier columns have higher priority).
    ///   - ascending: Parallel array of sort directions (`true` = ascending).
    ///   - child: The upstream plan whose output is sorted.
    case sort(by: [String], ascending: [Bool], QueryPlan)

    /// Binary node: joins two sub-plans on a shared key column.
    ///
    /// - Parameters:
    ///   - left: The left-hand (driving) plan.
    ///   - right: The right-hand (probed) plan.
    ///   - on: The join key column name (must exist in both sides).
    ///   - how: The join strategy (inner, left, right, outer).
    case join(left: QueryPlan, right: QueryPlan, on: String, how: MergeHow)

    /// Unary node: keeps only the first `n` rows of the child plan's output.
    ///
    /// - Parameters:
    ///   - n: Maximum number of rows to retain.
    ///   - child: The upstream plan whose output is truncated.
    case limit(Int, QueryPlan)

    // MARK: - Static Analysis Helpers

    /// The direct child plan(s) of this node.
    ///
    /// - `.scan` returns an empty array (leaf node).
    /// - Unary nodes (filter, select, groupBy, sort, limit) return a single-element array.
    /// - `.join` returns a two-element array `[left, right]`.
    var children: [QueryPlan] {
        switch self {
        case .scan:
            return []
        case .filter(_, let child), .select(_, let child),
             .groupBy(_, _, let child), .sort(_, _, let child),
             .limit(_, let child):
            return [child]
        case .join(let left, let right, _, _):
            return [left, right]
        }
    }

    /// The column names this node would produce, if statically determinable.
    ///
    /// Returns `nil` when the output schema cannot be inferred without executing
    /// the plan (this is a conservative fallback that prevents incorrect rewrites).
    ///
    /// The optimizer uses this to decide whether a predicate's referenced columns
    /// exist in a given sub-plan, which gates predicate pushdown and projection
    /// pushdown decisions.
    ///
    /// - Note: For `.groupBy`, the output is the group keys followed by all
    ///   non-key columns (which become the aggregated value columns). This is an
    ///   approximation -- the actual output depends on which columns are numeric,
    ///   but static analysis cannot determine types without executing.
    var outputColumns: [String]? {
        switch self {
        case .scan(let df):
            return df.columnNames
        case .select(let cols, _):
            return cols
        case .filter(_, let child), .sort(_, _, let child), .limit(_, let child):
            return child.outputColumns
        case .groupBy(let by, _, let child):
            guard let childCols = child.outputColumns else { return nil }
            let numericCols = childCols.filter { !by.contains($0) }
            return by + numericCols
        case .join(let left, let right, let key, _):
            guard let leftCols = left.outputColumns, let rightCols = right.outputColumns else { return nil }
            let rightNonKey = rightCols.filter { $0 != key }
            return leftCols + rightNonKey
        }
    }

    /// The row count of the deepest `.scan` leaf node, if reachable.
    ///
    /// This follows the leftmost child path down to the scan and returns
    /// its `DataFrame.rowCount`. Used by ``prettyPrint(indent:)`` and the
    /// ``LazyDataFrame/explain()`` output to give the user an idea of the
    /// source data size.
    var scanRowCount: Int? {
        switch self {
        case .scan(let df): return df.rowCount
        case .filter(_, let child), .select(_, let child),
             .groupBy(_, _, let child), .sort(_, _, let child),
             .limit(_, let child):
            return child.scanRowCount
        case .join(let left, _, _, _):
            return left.scanRowCount
        }
    }

    /// The column count of the deepest `.scan` leaf node, if reachable.
    ///
    /// Mirrors ``scanRowCount`` but for columns. Together they describe the
    /// dimensions of the original data source for display purposes.
    var scanColumnCount: Int? {
        switch self {
        case .scan(let df): return df.columnCount
        case .filter(_, let child), .select(_, let child),
             .groupBy(_, _, let child), .sort(_, _, let child),
             .limit(_, let child):
            return child.scanColumnCount
        case .join(let left, _, _, _):
            return left.scanColumnCount
        }
    }
}

// MARK: - Pretty Printing

extension QueryPlan: CustomStringConvertible {
    /// A human-readable, indented string representation of the plan tree.
    ///
    /// Each node is printed on its own line with two-space indentation per depth
    /// level, producing output like:
    ///
    /// ```
    /// Filter(revenue > 1000.0)
    ///   Select(["name", "revenue"])
    ///     Scan(DataFrame: 500 rows x 4 cols)
    /// ```
    public var description: String {
        prettyPrint(indent: 0)
    }

    /// Recursively formats the plan tree with the given indentation depth.
    ///
    /// - Parameter indent: The current depth (number of two-space indentation levels).
    /// - Returns: A multi-line string representation of this node and all descendants.
    func prettyPrint(indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch self {
        case .scan(let df):
            return "\(pad)Scan(DataFrame: \(df.rowCount) rows × \(df.columnCount) cols)"
        case .filter(let pred, let child):
            return "\(pad)Filter(\(pred))\n\(child.prettyPrint(indent: indent + 1))"
        case .select(let cols, let child):
            return "\(pad)Select(\(cols))\n\(child.prettyPrint(indent: indent + 1))"
        case .groupBy(let by, let agg, let child):
            return "\(pad)GroupBy(by: \(by), agg: \(agg))\n\(child.prettyPrint(indent: indent + 1))"
        case .sort(let by, let asc, let child):
            let dirs = zip(by, asc).map { "\($0)\($1 ? "↑" : "↓")" }
            return "\(pad)Sort(\(dirs.joined(separator: ", ")))\n\(child.prettyPrint(indent: indent + 1))"
        case .join(let left, let right, let key, let how):
            return "\(pad)Join(on: \(key), how: \(how))\n\(left.prettyPrint(indent: indent + 1))\n\(right.prettyPrint(indent: indent + 1))"
        case .limit(let n, let child):
            return "\(pad)Limit(\(n))\n\(child.prettyPrint(indent: indent + 1))"
        }
    }
}
