// MARK: - QueryOptimizer.swift
//
// This file implements the four-pass query optimizer that rewrites a logical
// `QueryPlan` tree for better execution performance before the `QueryExecutor`
// materializes it.
//
// ## Architecture Overview
//
// The optimizer is a stateless, pure-function rewrite engine exposed as a
// caseless `enum` (preventing instantiation). Its single public entry point,
// `optimize(_:)`, applies four transformation passes in a fixed order:
//
//   1. **Filter Fusion** — merges consecutive `.filter` nodes into a single
//      `.filter` with a conjunctive (`.and`) predicate, eliminating redundant
//      intermediate mask evaluations at execution time.
//
//   2. **Predicate Pushdown** — moves `.filter` nodes downward in the tree
//      past `.sort`, `.groupBy`, `.select`, and into `.join` branches when
//      the predicate's referenced columns are available in the target sub-plan.
//      This reduces the number of rows processed by expensive operations
//      (sorting, hashing for group-by, etc.).
//
//   3. **Projection Pushdown** — moves `.select` nodes earlier in the plan so
//      that unused columns are dropped before they flow through filters, sorts,
//      and group-bys. This reduces memory bandwidth and cache pressure.
//
//   4. **Redundant Elimination** — simplifies degenerate patterns:
//      - Consecutive `.limit` nodes collapse into `limit(min(n, m), source)`.
//      - A `.select` that lists every column of a `.scan` in order is removed.
//
// Each pass is a recursive function that pattern-matches on plan node
// combinations. The passes are intentionally ordered so that earlier passes
// expose opportunities for later ones (e.g., filter fusion creates larger
// predicates that predicate pushdown can then move).
//
// ## Safety Invariants
//
// - **Predicate pushdown past groupBy** is only performed when *every* column
//   referenced by the predicate exists in the source plan's output schema.
//   This prevents pushing a filter on an aggregated column (e.g., a sum) below
//   the group-by that creates it.
//
// - **Projection pushdown past filter** preserves the filter's referenced
//   columns by taking the union of the outer select's columns and the
//   predicate's referenced columns.
//
// - **Projection pushdown past groupBy** preserves the group-by key columns
//   in the inner select, ensuring the group-by always has its keys available.
//
// ## Extensibility
//
// Additional passes (e.g., join reordering, common sub-expression elimination)
// can be appended to the `optimize(_:)` pipeline without changing the rest of
// the lazy engine.

/// Query optimizer that rewrites logical ``QueryPlan`` trees for better
/// execution performance.
///
/// `QueryOptimizer` is a caseless `enum` (no instances) that exposes a single
/// static entry point, ``optimize(_:)``, which applies all four optimization
/// passes in sequence. Each pass is a recursive tree rewrite that
/// pattern-matches on specific node combinations.
///
/// ## Optimization Passes
///
/// 1. **Filter fusion** -- merges consecutive `.filter` nodes into a single
///    `.filter(.and(...), source)`.
/// 2. **Predicate pushdown** -- moves filters below sorts, group-bys, selects,
///    and into join branches when safe.
/// 3. **Projection pushdown** -- pushes column selections earlier to reduce
///    intermediate data width.
/// 4. **Redundant elimination** -- removes identity selects and collapses
///    consecutive limits.
///
/// ## Thread Safety
///
/// All methods are pure functions with no mutable state, making them safe to
/// call from any context.
public enum QueryOptimizer {

    /// Optimize a query plan by applying all four optimization passes in sequence.
    ///
    /// The passes are applied in a fixed order chosen so that earlier passes expose
    /// opportunities for later ones:
    ///
    /// 1. Filter fusion merges adjacent filters, creating single compound predicates.
    /// 2. Predicate pushdown moves those (potentially fused) filters closer to the scan.
    /// 3. Projection pushdown narrows the data flowing through the (now-reordered) plan.
    /// 4. Redundant elimination cleans up any degenerate patterns introduced by the
    ///    previous passes (e.g., an identity select produced by projection pushdown).
    ///
    /// - Parameter plan: The unoptimized logical query plan.
    /// - Returns: A semantically equivalent plan that is expected to execute faster.
    /// - Complexity: Each pass visits every node once, so the total cost is O(4 * *n*)
    ///   where *n* is the number of nodes in the plan tree.
    public static func optimize(_ plan: QueryPlan) -> QueryPlan {
        var result = plan
        // Pass 1: merge consecutive .filter nodes into single .and predicates
        result = filterFusion(result)
        // Pass 2: move filters below sort/groupBy/select/join when safe
        result = predicatePushdown(result)
        // Pass 3: push column selections earlier to reduce intermediate width
        result = projectionPushdown(result)
        // Pass 4: remove identity selects and collapse consecutive limits
        result = redundantElimination(result)
        return result
    }

    // MARK: - Pass 1: Filter Fusion

    /// Merge consecutive `.filter` nodes into a single filter with a conjunctive predicate.
    ///
    /// **Pattern:**
    /// ```
    /// filter(p1, filter(p2, source))  -->  filter(p1 AND p2, source)
    /// ```
    ///
    /// When the user writes `.filter(a).filter(b)`, the plan contains two nested
    /// filter nodes. Without fusion, the executor would evaluate two separate boolean
    /// masks and apply two separate row-selection passes. Fusion combines them into one
    /// `.and(a, b)` predicate so only a single mask evaluation and selection pass is
    /// needed.
    ///
    /// The method recurses into all node types so that deeply nested consecutive
    /// filters are caught regardless of where they appear in the tree.
    ///
    /// - Parameter plan: The plan tree (or sub-tree) to rewrite.
    /// - Returns: An equivalent plan with all consecutive filter pairs fused.
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

    // MARK: - Pass 2: Predicate Pushdown

    /// Move `.filter` nodes downward past other operations when doing so is
    /// semantically safe, so that fewer rows flow through expensive operations.
    ///
    /// **Supported rewrites:**
    ///
    /// | Pattern | Condition | Result |
    /// |---------|-----------|--------|
    /// | `filter(p, sort(..., src))` | Always safe | `sort(..., filter(p, src))` |
    /// | `filter(p, groupBy(keys, agg, src))` | `p.referencedColumns` subset of `src.outputColumns` | `groupBy(keys, agg, filter(p, src))` |
    /// | `filter(p, select(cols, src))` | `p.referencedColumns` subset of `cols` | `select(cols, filter(p, src))` |
    /// | `filter(p, join(L, R, ...))` | `p.referencedColumns` subset of left output | `join(filter(p, L), R, ...)` |
    /// | `filter(p, join(L, R, ...))` | `p.referencedColumns` subset of right output | `join(L, filter(p, R), ...)` |
    ///
    /// The key insight is that filtering does not change the *set* of columns or the
    /// *order* of rows (it only removes rows), so it commutes safely with projections
    /// and sorts. For group-by, the filter must reference only pre-aggregation columns
    /// to avoid filtering on values that do not yet exist.
    ///
    /// - Parameter plan: The plan tree (or sub-tree) to rewrite.
    /// - Returns: An equivalent plan with filters pushed as close to the scan as possible.
    static func predicatePushdown(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // Push filter below sort: always safe because filtering only removes rows
        // without affecting the relative order of the remaining rows.
        case .filter(let pred, .sort(let by, let asc, let source)):
            return predicatePushdown(.sort(by: by, ascending: asc, .filter(pred, source)))

        // Push filter below groupBy: only safe when the predicate references
        // columns that exist in the pre-aggregation source (not computed aggregates).
        case .filter(let pred, .groupBy(let by, let agg, let source)):
            let predCols = pred.referencedColumns
            let sourceCols = source.outputColumns.map(Set.init) ?? Set<String>()
            // Guard: only push if we can confirm all referenced columns exist in source
            if !sourceCols.isEmpty && predCols.isSubset(of: sourceCols) {
                return predicatePushdown(.groupBy(by: by, agg: agg, .filter(pred, source)))
            }
            // Cannot push: predicate may reference aggregated columns; recurse into child only
            return .filter(pred, .groupBy(by: by, agg: agg, predicatePushdown(source)))

        // Push filter below select: safe when all predicate columns survive the projection.
        case .filter(let pred, .select(let cols, let source)):
            let predCols = pred.referencedColumns
            if predCols.isSubset(of: Set(cols)) {
                return predicatePushdown(.select(cols, .filter(pred, source)))
            }
            // Cannot push: predicate references columns that the select would drop
            return .filter(pred, .select(cols, predicatePushdown(source)))

        // Push filter into the appropriate branch of a join: route to left or right
        // side based on which side's columns the predicate references.
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

    // MARK: - Pass 3: Projection Pushdown

    /// Push `.select` nodes earlier in the plan to reduce the width of
    /// intermediate DataFrames, lowering memory bandwidth and cache pressure.
    ///
    /// **Supported rewrites:**
    ///
    /// | Pattern | Action |
    /// |---------|--------|
    /// | `select(A, select(B, src))` | Collapse to `select(A, src)` (outer wins) |
    /// | `select(A, groupBy(keys, agg, src))` | Insert inner `select(keys + needed, src)` if it reduces width |
    /// | `select(A, filter(pred, src))` | Push `select(A union pred.cols, src)` below filter |
    ///
    /// The key challenge is ensuring that columns needed by downstream nodes
    /// (filter predicates, group-by keys) are preserved in the pushed-down select.
    /// The method computes the union of the outer select's columns and any
    /// additional columns required by the intervening operation.
    ///
    /// - Parameter plan: The plan tree (or sub-tree) to rewrite.
    /// - Returns: An equivalent plan with projections pushed toward the scan.
    static func projectionPushdown(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // Consecutive selects: the outer select already lists exactly the columns we
        // want, so the inner select is redundant. Drop it and recurse.
        case .select(let outerCols, .select(_, let source)):
            return projectionPushdown(.select(outerCols, source))

        // Select above groupBy: try to insert an inner select on the source that
        // keeps only the group keys plus the value columns that the outer select needs.
        // This avoids carrying wide rows through the groupBy hash table.
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

        // Select above filter: push the select below the filter so that fewer columns
        // are materialized before filtering. The pushed-down select must include the
        // union of the outer select's columns and the filter predicate's referenced
        // columns, since the filter needs those columns to evaluate its mask.
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

    // MARK: - Pass 4: Redundant Elimination

    /// Remove or simplify degenerate plan patterns that add no value.
    ///
    /// **Supported rewrites:**
    ///
    /// | Pattern | Result |
    /// |---------|--------|
    /// | `limit(n, limit(m, source))` | `limit(min(n, m), source)` |
    /// | `select(cols, scan(df))` where `cols == df.columnNames` | `scan(df)` |
    ///
    /// The first rule handles `.head(10).head(5)` chains by keeping only the
    /// smaller limit. The second rule detects projections that select every column
    /// in its original order -- these are no-ops left behind by earlier passes
    /// (especially projection pushdown) and can be safely removed.
    ///
    /// - Parameter plan: The plan tree (or sub-tree) to simplify.
    /// - Returns: An equivalent plan with redundant nodes removed.
    static func redundantElimination(_ plan: QueryPlan) -> QueryPlan {
        switch plan {
        // Consecutive limits: keep the stricter (smaller) bound. For example,
        // `.head(100).head(10)` becomes `.head(10)`.
        case .limit(let n, .limit(let m, let source)):
            return redundantElimination(.limit(Swift.min(n, m), source))

        // Identity select: a select that lists every column of the underlying scan
        // in the same order is a no-op -- remove it entirely.
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
