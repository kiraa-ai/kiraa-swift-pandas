/// Aggregation operations for lazy GroupBy.
public enum AggOp: Sendable, Equatable {
    case sum, mean, count, min, max
}

/// A logical query plan node.
///
/// Uses `indirect enum` for recursive tree structure — each node wraps
/// its child plan(s), forming a tree that the optimizer can rewrite.
public indirect enum QueryPlan: Sendable {
    /// Scan an in-memory DataFrame (leaf node).
    case scan(DataFrame)

    /// Filter rows matching a predicate.
    case filter(ColumnPredicate, QueryPlan)

    /// Select specific columns (projection).
    case select([String], QueryPlan)

    /// Group by columns and aggregate.
    case groupBy(by: [String], agg: AggOp, QueryPlan)

    /// Sort by columns.
    case sort(by: [String], ascending: [Bool], QueryPlan)

    /// Join two plans on a key.
    case join(left: QueryPlan, right: QueryPlan, on: String, how: MergeHow)

    /// Take first N rows.
    case limit(Int, QueryPlan)

    // MARK: - Analysis

    /// The child plan(s) of this node.
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

    /// Output columns if statically known (without executing).
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

    /// Estimated row count for scan nodes (helpful for explain output).
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

    /// Estimated scan column count.
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

// MARK: - Pretty printing

extension QueryPlan: CustomStringConvertible {
    public var description: String {
        prettyPrint(indent: 0)
    }

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
