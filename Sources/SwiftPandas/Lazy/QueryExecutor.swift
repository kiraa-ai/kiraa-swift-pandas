// MARK: - QueryExecutor.swift
//
// This file implements the recursive executor that walks an optimized `QueryPlan`
// tree and materializes a concrete `DataFrame`.
//
// ## Architecture Overview
//
// `QueryExecutor` is a caseless `enum` (no instances) with a single public
// static method, `execute(_:)`. It performs a **bottom-up, depth-first** traversal
// of the plan tree:
//
//   1. Recurse into child plan(s) to obtain intermediate `DataFrame`(s).
//   2. Apply the current node's operation using the corresponding eager
//      `DataFrame` / `GroupBy` method.
//   3. Return the resulting `DataFrame` to the parent node.
//
// Because every node delegates to the eager DataFrame API, the executor
// automatically benefits from all existing low-level optimizations:
//
//   - **Accelerate / vDSP** vectorized arithmetic in Series and aggregations.
//   - **Metal GPU kernels** for large-scale numeric operations (when available).
//   - **Factorized GroupBy** with pre-computed hash indices for fast aggregation.
//   - **Optimized merge** with hash-join and sort-merge strategies.
//
// ## Execution Order
//
// The plan is always executed **after** the `QueryOptimizer` has rewritten it.
// This means filters have been fused and pushed down, projections have been
// narrowed, and redundant nodes have been eliminated. The executor does not
// perform any optimization itself — it trusts that the plan it receives is
// already in an efficient form.
//
// ## Node Dispatch Table
//
// | Plan Node | Eager Method Called |
// |-----------|--------------------|
// | `.scan(df)` | Returns `df` directly (no work) |
// | `.filter(pred, src)` | `pred.evaluate(on:)` then `df.filter(mask:)` |
// | `.select(cols, src)` | `df.select(columns:)` |
// | `.groupBy(by, agg, src)` | `df.groupBy(...)` then `gb.sum()/mean()/...` |
// | `.sort(by, asc, src)` | `df.sortValues(by:ascending:)` |
// | `.join(L, R, key, how)` | `leftDF.merge(rightDF, on:how:)` |
// | `.limit(n, src)` | `df.head(n)` |
//
// ## Thread Safety
//
// The executor is a pure function with no mutable state. It is safe to call
// from any context, though the underlying DataFrame operations may allocate
// memory and are not designed for concurrent mutation of the same DataFrame.

/// Recursive executor that materializes an optimized ``QueryPlan`` into a
/// concrete ``DataFrame`` by dispatching each plan node to the corresponding
/// eager DataFrame operation.
///
/// `QueryExecutor` is a caseless `enum` (cannot be instantiated) with a single
/// static entry point, ``execute(_:)``. It performs a depth-first, bottom-up
/// traversal: child plans are executed first to produce intermediate DataFrames,
/// then the current node's operation is applied on top.
///
/// Because every node delegates to the existing eager API, the executor
/// automatically inherits all low-level optimizations (Accelerate/vDSP, Metal
/// GPU, factorized GroupBy) without any additional implementation.
///
/// ## Example
///
/// ```swift
/// let optimizedPlan = QueryOptimizer.optimize(rawPlan)
/// let result: DataFrame = QueryExecutor.execute(optimizedPlan)
/// ```
///
/// In practice, users do not call this directly — ``LazyDataFrame/collect()``
/// invokes the optimizer and executor internally.
public enum QueryExecutor {

    /// Execute a query plan tree and return the fully materialized ``DataFrame``.
    ///
    /// The method recursively evaluates child plans first (bottom-up), then applies
    /// the current node's operation. For binary nodes (`.join`), both children are
    /// evaluated independently before the join is performed.
    ///
    /// - Parameter plan: An optimized ``QueryPlan`` tree (typically produced by
    ///   ``QueryOptimizer/optimize(_:)``).
    /// - Returns: A concrete ``DataFrame`` representing the result of the entire plan.
    /// - Complexity: Depends on the plan structure and data size. Each node contributes
    ///   the complexity of its corresponding eager DataFrame operation.
    public static func execute(_ plan: QueryPlan) -> DataFrame {
        switch plan {
        // Leaf node: the scan holds the source DataFrame directly — no work needed.
        case .scan(let df):
            return df

        // Filter: evaluate the predicate expression tree to produce a boolean mask,
        // then apply the mask to keep only matching rows.
        case .filter(let predicate, let source):
            let df = execute(source)
            let mask = predicate.evaluate(on: df)
            return df.filter(mask: mask)

        // Projection: keep only the named columns, discarding all others.
        case .select(let columns, let source):
            let df = execute(source)
            return df.select(columns: columns)

        // GroupBy + aggregation: create a GroupBy handle (using the single-column
        // fast path when there is exactly one key), then dispatch to the appropriate
        // aggregation method based on the AggOp tag.
        case .groupBy(let by, let agg, let source):
            let df = execute(source)
            let gb: GroupBy
            if by.count == 1 {
                // Single-column groupBy uses an optimized hash path
                gb = df.groupBy(by[0])
            } else {
                // Multi-column groupBy computes a composite key
                gb = df.groupBy(by)
            }
            switch agg {
            case .sum: return gb.sum()
            case .mean: return gb.mean()
            case .count: return gb.count()
            case .min: return gb.min()
            case .max: return gb.max()
            }

        // Sort: delegate to the eager multi-column sort implementation.
        case .sort(let by, let asc, let source):
            let df = execute(source)
            return df.sortValues(by: by, ascending: asc)

        // Join: execute both sides independently, then merge. The eager merge
        // implementation selects between hash-join and sort-merge internally.
        case .join(let left, let right, let key, let how):
            let leftDF = execute(left)
            let rightDF = execute(right)
            return leftDF.merge(rightDF, on: key, how: how)

        // Limit: execute the child, then truncate to the first n rows.
        case .limit(let n, let source):
            let df = execute(source)
            return df.head(n)
        }
    }
}
