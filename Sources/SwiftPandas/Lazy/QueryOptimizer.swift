/// Query optimizer that rewrites logical plans for better performance.
///
/// Applies multiple optimization passes bottom-up:
/// 1. **Filter fusion**: merges consecutive filters into AND
/// 2. **Predicate pushdown**: moves filters below sort/groupBy when safe
/// 3. **Projection pushdown**: eliminates unused columns early
/// 4. **Redundant elimination**: simplifies redundant select/limit chains
public enum QueryOptimizer {

    /// Optimize a query plan by applying all optimization passes.
    public static func optimize(_ plan: QueryPlan) -> QueryPlan {
        var result = plan
        // Multiple passes — each may expose new optimization opportunities
        result = filterFusion(result)
        result = predicatePushdown(result)
        result = projectionPushdown(result)
        result = redundantElimination(result)
        return result
    }

    // MARK: - Filter Fusion

    /// Merge consecutive filter nodes into a single filter with AND.
    /// `filter(p1, filter(p2, source))` → `filter(p1 AND p2, source)`
    static func filterFusion(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        case .filter(let p1, .filter(let p2, let source)):
            // Recurse into the merged filter's source
            return filterFusion(.filter(.and(p1, p2), source))

        case .filter(let pred, let child):
            return .filter(pred, filterFusion(child))

        case .select(let cols, let child):
            return .select(cols, filterFusion(child))

        case .groupBy(let by, let agg, let child):
            return .groupBy(by: by, agg: agg, filterFusion(child))

        case .sort(let by, let asc, let child):
            return .sort(by: by, ascending: asc, filterFusion(child))

        case .join(let left, let right, let key, let how):
            return .join(left: filterFusion(left), right: filterFusion(right), on: key, how: how)

        case .limit(let n, let child):
            return .limit(n, filterFusion(child))

        case .scan:
            return plan
        }
    }

    // MARK: - Predicate Pushdown

    /// Move filter below sort and groupBy when the predicate only references
    /// columns that exist in the source (not aggregated columns).
    static func predicatePushdown(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // Push filter below sort — always valid since filter doesn't change sort order
        case .filter(let pred, .sort(let by, let asc, let source)):
            return predicatePushdown(.sort(by: by, ascending: asc, .filter(pred, source)))

        // Push filter below groupBy only when predicate references source columns
        case .filter(let pred, .groupBy(let by, let agg, let source)):
            let predCols = pred.referencedColumns
            let sourceCols = source.outputColumns.map(Set.init) ?? Set<String>()
            // Only push down if ALL referenced columns exist in source
            if !sourceCols.isEmpty && predCols.isSubset(of: sourceCols) {
                return predicatePushdown(.groupBy(by: by, agg: agg, .filter(pred, source)))
            }
            return .filter(pred, .groupBy(by: by, agg: agg, predicatePushdown(source)))

        // Push filter below select if all referenced columns are in the select list
        case .filter(let pred, .select(let cols, let source)):
            let predCols = pred.referencedColumns
            if predCols.isSubset(of: Set(cols)) {
                return predicatePushdown(.select(cols, .filter(pred, source)))
            }
            return .filter(pred, .select(cols, predicatePushdown(source)))

        // Push filter into join: if predicate only references left side, push left
        case .filter(let pred, .join(let left, let right, let key, let how)):
            let predCols = pred.referencedColumns
            let leftCols = left.outputColumns.map(Set.init) ?? Set<String>()
            let rightCols = right.outputColumns.map(Set.init) ?? Set<String>()

            if !leftCols.isEmpty && predCols.isSubset(of: leftCols) {
                return predicatePushdown(.join(left: .filter(pred, left), right: right, on: key, how: how))
            }
            if !rightCols.isEmpty && predCols.isSubset(of: rightCols) {
                return predicatePushdown(.join(left: left, right: .filter(pred, right), on: key, how: how))
            }
            return .filter(pred, .join(left: predicatePushdown(left), right: predicatePushdown(right), on: key, how: how))

        // Recurse into other nodes
        case .filter(let pred, let child):
            return .filter(pred, predicatePushdown(child))

        case .select(let cols, let child):
            return .select(cols, predicatePushdown(child))

        case .groupBy(let by, let agg, let child):
            return .groupBy(by: by, agg: agg, predicatePushdown(child))

        case .sort(let by, let asc, let child):
            return .sort(by: by, ascending: asc, predicatePushdown(child))

        case .join(let left, let right, let key, let how):
            return .join(left: predicatePushdown(left), right: predicatePushdown(right), on: key, how: how)

        case .limit(let n, let child):
            return .limit(n, predicatePushdown(child))

        case .scan:
            return plan
        }
    }

    // MARK: - Projection Pushdown

    /// Push select nodes earlier to reduce intermediate data width.
    /// Computes needed columns from downstream operations and inserts select
    /// nodes to eliminate unused columns.
    static func projectionPushdown(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // select → select: combine into single select (intersection preserving order)
        case .select(let outerCols, .select(_, let source)):
            return projectionPushdown(.select(outerCols, source))

        // select → groupBy: ensure select includes group keys + needed numeric cols
        case .select(let outerCols, .groupBy(let by, let agg, let source)):
            let neededFromSource = Set(outerCols).union(by)
            if let sourceCols = source.outputColumns {
                let trimmed = sourceCols.filter { neededFromSource.contains($0) || !by.contains($0) }
                // Only add inner select if it actually reduces columns
                if trimmed.count < sourceCols.count {
                    // Need group keys + all columns that could be aggregated among outerCols
                    let innerCols = sourceCols.filter { by.contains($0) || outerCols.contains($0) }
                    return .select(outerCols, .groupBy(by: by, agg: agg, projectionPushdown(.select(innerCols, source))))
                }
            }
            return .select(outerCols, .groupBy(by: by, agg: agg, projectionPushdown(source)))

        // select → filter: push select below filter, but keep filter's referenced columns
        case .select(let cols, .filter(let pred, let source)):
            let needed = Set(cols).union(pred.referencedColumns)
            let neededCols = source.outputColumns?.filter { needed.contains($0) } ?? Array(needed)
            return projectionPushdown(.filter(pred, .select(neededCols, source)))

        // Recurse into other nodes
        case .select(let cols, let child):
            return .select(cols, projectionPushdown(child))

        case .filter(let pred, let child):
            return .filter(pred, projectionPushdown(child))

        case .groupBy(let by, let agg, let child):
            return .groupBy(by: by, agg: agg, projectionPushdown(child))

        case .sort(let by, let asc, let child):
            return .sort(by: by, ascending: asc, projectionPushdown(child))

        case .join(let left, let right, let key, let how):
            return .join(left: projectionPushdown(left), right: projectionPushdown(right), on: key, how: how)

        case .limit(let n, let child):
            return .limit(n, projectionPushdown(child))

        case .scan:
            return plan
        }
    }

    // MARK: - Redundant Elimination

    /// Remove redundant operations.
    /// - `limit(n, limit(m, source))` → `limit(min(n,m), source)`
    /// - `select(cols, scan)` where cols == all scan columns → remove select
    static func redundantElimination(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // Combine consecutive limits
        case .limit(let n, .limit(let m, let source)):
            return redundantElimination(.limit(Swift.min(n, m), source))

        // Remove identity select (selecting all columns in order)
        case .select(let cols, .scan(let df)) where cols == df.columnNames:
            return .scan(df)

        // Recurse
        case .filter(let pred, let child):
            return .filter(pred, redundantElimination(child))

        case .select(let cols, let child):
            return .select(cols, redundantElimination(child))

        case .groupBy(let by, let agg, let child):
            return .groupBy(by: by, agg: agg, redundantElimination(child))

        case .sort(let by, let asc, let child):
            return .sort(by: by, ascending: asc, redundantElimination(child))

        case .join(let left, let right, let key, let how):
            return .join(left: redundantElimination(left), right: redundantElimination(right), on: key, how: how)

        case .limit(let n, let child):
            return .limit(n, redundantElimination(child))

        case .scan:
            return plan
        }
    }
}
