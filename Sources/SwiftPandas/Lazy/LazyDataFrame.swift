// MARK: - LazyDataFrame.swift
//
// This file implements the lazy evaluation front-end for SwiftPandas DataFrames.
//
// ## Architecture Overview
//
// Traditional (eager) DataFrame operations execute immediately: calling `df.filter(...)`
// materializes a brand-new DataFrame on every call. When several operations are chained
// together — filter, select, sort, group — each one produces a full intermediate copy
// of the data, even though only the final result is needed.
//
// `LazyDataFrame` solves this by **deferring computation**. Instead of executing work
// immediately, each method appends a logical operation node to an internal `QueryPlan`
// tree. No rows are read, filtered, or sorted until the user explicitly calls
// `.collect()`. At that point the complete plan is handed to the `QueryOptimizer`,
// which rewrites it for efficiency (filter fusion, predicate pushdown, projection
// pushdown, redundant elimination), and finally the `QueryExecutor` walks the
// optimized tree and materializes the result in a single pass.
//
// ## Lifecycle of a Lazy Query
//
// 1. **Plan building** — The user calls `df.lazy()` to obtain a `LazyDataFrame` whose
//    plan is a single `.scan(df)` leaf node. Each subsequent method call (`.filter()`,
//    `.select()`, `.sort()`, etc.) wraps the existing plan inside a new node, producing
//    a progressively deeper tree. Because `LazyDataFrame` is a value type (`struct`)
//    and `QueryPlan` is `Sendable`, plans are safe to share across threads.
//
// 2. **Optimization** — `QueryOptimizer.optimize(_:)` applies a fixed sequence of
//    rewrite passes to the plan tree. See `QueryOptimizer.swift` for details.
//
// 3. **Execution** — `QueryExecutor.execute(_:)` recursively walks the optimized plan
//    bottom-up, dispatching each node to the corresponding eager `DataFrame` method.
//    This means every low-level optimization already present in the eager path
//    (Accelerate / vDSP vectorization, Metal GPU kernels, factorized GroupBy) is
//    reused automatically.
//
// ## Thread Safety
//
// Both `LazyDataFrame` and `LazyGroupBy` conform to `Sendable`. Plans are immutable
// value trees, so they can be safely passed across isolation boundaries.
//
// ## Usage Example
//
// ```swift
// let result = df.lazy()
//     .filter(col("revenue") > 1000)          // deferred — builds Filter node
//     .select("name", "region", "revenue")     // deferred — builds Select node
//     .groupBy("region").sum()                  // deferred — builds GroupBy node
//     .collect()                                // triggers optimize + execute
// ```

/// A lazily-evaluated DataFrame that builds a query plan instead of materializing data.
///
/// `LazyDataFrame` is the primary entry point for SwiftPandas's deferred-execution
/// engine. Every operation on a `LazyDataFrame` returns a **new** `LazyDataFrame`
/// instance whose internal ``QueryPlan`` tree has been extended with an additional
/// logical node. No data is read, copied, or transformed until ``collect()`` is
/// called.
///
/// This design delivers two key benefits:
///
/// 1. **No intermediate allocations.** A chain of five operations produces one final
///    DataFrame, not five intermediate copies.
/// 2. **Whole-query optimization.** Because the optimizer can see the entire pipeline
///    before any work happens, it can fuse filters, push predicates closer to the
///    data source, and eliminate columns that are never used downstream.
///
/// ## Creating a LazyDataFrame
///
/// Use the ``DataFrame/lazy()`` extension method:
///
/// ```swift
/// let lazy = myDataFrame.lazy()
/// ```
///
/// ## Materializing Results
///
/// Call ``collect()`` to optimize the plan and produce a concrete ``DataFrame``:
///
/// ```swift
/// let result = lazy
///     .filter(col("price") > 9.99)
///     .select("title", "price")
///     .collect()
/// ```
///
/// ## Inspecting the Plan
///
/// Use ``explain()`` to view the optimized plan, or ``explainRaw()`` to view the
/// unoptimized plan. Both return a human-readable, indented string representation.
public struct LazyDataFrame: Sendable {

    /// The logical query plan that describes the sequence of operations to perform.
    ///
    /// This tree is built incrementally by each method call and is never mutated
    /// in place — every method returns a new `LazyDataFrame` wrapping a new root
    /// node that references the previous plan as its child.
    internal let plan: QueryPlan

    /// Creates a `LazyDataFrame` from a pre-built query plan.
    ///
    /// This initializer is `internal` because callers should use ``DataFrame/lazy()``
    /// to enter the lazy context. It is used internally by every operation method to
    /// wrap an extended plan in a new `LazyDataFrame` value.
    ///
    /// - Parameter plan: The logical query plan tree for this lazy frame.
    internal init(plan: QueryPlan) {
        self.plan = plan
    }

    /// Optimize and execute the query plan, returning a fully materialized ``DataFrame``.
    ///
    /// This is the **terminal operation** that triggers actual computation. The method
    /// performs two steps:
    ///
    /// 1. Passes the internal ``QueryPlan`` through ``QueryOptimizer/optimize(_:)``,
    ///    which applies filter fusion, predicate pushdown, projection pushdown, and
    ///    redundant-node elimination.
    /// 2. Passes the rewritten plan to ``QueryExecutor/execute(_:)``, which recursively
    ///    evaluates each node bottom-up using the corresponding eager ``DataFrame``
    ///    methods.
    ///
    /// - Returns: A concrete ``DataFrame`` containing the final result.
    /// - Complexity: Depends on the operations in the plan and the size of the source
    ///   data. The optimizer may significantly reduce work compared to eager execution.
    public func collect() -> DataFrame {
        let optimized = QueryOptimizer.optimize(plan)
        return QueryExecutor.execute(optimized)
    }

    // MARK: - Operations

    /// Append a filter (row selection) node to the query plan.
    ///
    /// Rows for which `predicate` evaluates to `false` will be excluded from the
    /// result when the plan is eventually executed. Multiple successive `.filter()`
    /// calls are automatically merged into a single conjunctive predicate by the
    /// optimizer's filter-fusion pass.
    ///
    /// Because predicates are represented as an inspectable ``ColumnPredicate``
    /// expression tree (rather than opaque closures), the optimizer can analyze
    /// referenced columns and safely push the filter closer to the data source.
    ///
    /// - Parameter predicate: A ``ColumnPredicate`` describing the row condition.
    ///   Build predicates using ``col(_:)`` and comparison operators (e.g.,
    ///   `col("age") >= 18`).
    /// - Returns: A new ``LazyDataFrame`` whose plan wraps the current plan in a
    ///   `.filter` node.
    public func filter(_ predicate: ColumnPredicate) -> LazyDataFrame {
        LazyDataFrame(plan: .filter(predicate, plan))
    }

    /// Append a projection (column selection) node to the query plan.
    ///
    /// Only the named columns will be present in the output. Columns not listed are
    /// discarded. The optimizer's projection-pushdown pass may move this node earlier
    /// in the plan to reduce the width of intermediate data, and the redundant-
    /// elimination pass will remove it entirely if it selects all columns of the
    /// underlying scan in their original order.
    ///
    /// - Parameter columns: An array of column names to retain. Column order in the
    ///   output matches the order of this array.
    /// - Returns: A new ``LazyDataFrame`` with a `.select` node appended.
    public func select(_ columns: [String]) -> LazyDataFrame {
        LazyDataFrame(plan: .select(columns, plan))
    }

    /// Variadic convenience overload of ``select(_:)-swift.method`` for selecting
    /// columns by name without constructing an array.
    ///
    /// ```swift
    /// lazy.select("name", "age", "city")
    /// ```
    ///
    /// - Parameter columns: One or more column name strings.
    /// - Returns: A new ``LazyDataFrame`` with a `.select` node appended.
    public func select(_ columns: String...) -> LazyDataFrame {
        select(columns)
    }

    /// Append a node that drops the specified columns, keeping all others.
    ///
    /// Internally this resolves the current plan's ``QueryPlan/outputColumns`` and
    /// constructs a `.select` node containing the complement of the dropped set.
    /// If the output columns cannot be statically determined (e.g., because the
    /// plan contains a complex join), the method returns `self` unchanged as a
    /// safe fallback.
    ///
    /// - Parameter columns: An array of column names to remove from the output.
    /// - Returns: A new ``LazyDataFrame`` that excludes the named columns, or
    ///   `self` if output columns could not be determined.
    public func drop(_ columns: [String]) -> LazyDataFrame {
        guard let current = plan.outputColumns else { return self }
        let remaining = current.filter { !columns.contains($0) }
        return select(remaining)
    }

    /// Append a sort node to the query plan.
    ///
    /// Sorting is deferred — no data is reordered until ``collect()`` is called.
    /// If a filter is later appended on top of this sort, the optimizer's predicate-
    /// pushdown pass will move the filter below the sort (since filtering does not
    /// affect sort order), potentially reducing the number of rows that need sorting.
    ///
    /// - Parameters:
    ///   - columns: Column names to sort by. Earlier columns have higher priority
    ///     (i.e., ties in the first column are broken by the second, and so on).
    ///   - ascending: A parallel array of booleans indicating sort direction for each
    ///     column. `true` means ascending (smallest first), `false` means descending.
    ///     If `nil`, all columns default to ascending.
    /// - Returns: A new ``LazyDataFrame`` with a `.sort` node appended.
    public func sort(by columns: [String], ascending: [Bool]? = nil) -> LazyDataFrame {
        let asc = ascending ?? [Bool](repeating: true, count: columns.count)
        return LazyDataFrame(plan: .sort(by: columns, ascending: asc, plan))
    }

    /// Single-column convenience overload of ``sort(by:ascending:)-swift.method``.
    ///
    /// - Parameters:
    ///   - column: The column name to sort by.
    ///   - ascending: Sort direction. Defaults to `true` (ascending / smallest first).
    /// - Returns: A new ``LazyDataFrame`` with a `.sort` node appended.
    public func sort(by column: String, ascending: Bool = true) -> LazyDataFrame {
        sort(by: [column], ascending: [ascending])
    }

    /// Append a limit node that retains only the first `n` rows.
    ///
    /// Consecutive `.head()` calls are collapsed by the optimizer's redundant-
    /// elimination pass into a single `.limit(min(n, m), source)` node.
    ///
    /// - Parameter n: The maximum number of rows to keep. Must be non-negative.
    /// - Returns: A new ``LazyDataFrame`` with a `.limit` node appended.
    public func head(_ n: Int) -> LazyDataFrame {
        LazyDataFrame(plan: .limit(n, plan))
    }

    /// Begin a lazy group-by operation on one or more columns (variadic).
    ///
    /// Returns a ``LazyGroupBy`` handle on which you must call an aggregation method
    /// (`.sum()`, `.mean()`, `.count()`, `.min()`, `.max()`) to complete the group-by
    /// and obtain a new ``LazyDataFrame``.
    ///
    /// ```swift
    /// lazy.groupBy("region", "category").sum()
    /// ```
    ///
    /// - Parameter columns: One or more column names to group by.
    /// - Returns: A ``LazyGroupBy`` bound to this plan and the specified grouping
    ///   columns.
    public func groupBy(_ columns: String...) -> LazyGroupBy {
        LazyGroupBy(plan: plan, by: columns)
    }

    /// Begin a lazy group-by operation on one or more columns (array).
    ///
    /// This overload accepts a pre-built array of column names, which is useful when
    /// the grouping columns are determined at runtime.
    ///
    /// - Parameter columns: An array of column names to group by.
    /// - Returns: A ``LazyGroupBy`` bound to this plan and the specified grouping
    ///   columns.
    public func groupBy(_ columns: [String]) -> LazyGroupBy {
        LazyGroupBy(plan: plan, by: columns)
    }

    /// Append a join node that merges this lazy frame with another on a shared key.
    ///
    /// The join is deferred — both sides of the join are represented as sub-plans in
    /// the query tree. The optimizer can push filters into either side independently
    /// when the predicate references only columns from that side.
    ///
    /// - Parameters:
    ///   - other: The right-hand ``LazyDataFrame`` to join with.
    ///   - key: The column name that must exist in both frames and is used for
    ///     matching rows.
    ///   - how: The join strategy (`.inner`, `.left`, `.right`, `.outer`). Defaults
    ///     to `.inner`.
    /// - Returns: A new ``LazyDataFrame`` with a `.join` node whose children are the
    ///   plans of `self` (left) and `other` (right).
    public func merge(_ other: LazyDataFrame, on key: String, how: MergeHow = .inner) -> LazyDataFrame {
        LazyDataFrame(plan: .join(left: plan, right: other.plan, on: key, how: how))
    }

    // MARK: - Explain

    /// Return a human-readable, indented representation of the **optimized** query plan.
    ///
    /// This is the plan that ``collect()`` would actually execute. It is useful for
    /// debugging and verifying that the optimizer is rewriting the plan as expected.
    ///
    /// ```swift
    /// print(lazy.filter(col("x") > 0).select("x", "y").explain())
    /// // Optimized Plan:
    /// //   Filter(x > 0.0)
    /// //     Select(["x", "y"])
    /// //       Scan(DataFrame: 1000 rows × 5 cols)
    /// ```
    ///
    /// - Returns: A multi-line string prefixed with "Optimized Plan:".
    public func explain() -> String {
        let optimized = QueryOptimizer.optimize(plan)
        return "Optimized Plan:\n\(optimized.description)"
    }

    /// Return a human-readable, indented representation of the **raw** (unoptimized)
    /// query plan exactly as the user built it.
    ///
    /// Comparing the output of ``explainRaw()`` with ``explain()`` shows what
    /// transformations the optimizer applied.
    ///
    /// - Returns: A multi-line string prefixed with "Raw Plan:".
    public func explainRaw() -> String {
        "Raw Plan:\n\(plan.description)"
    }
}

// MARK: - LazyGroupBy

/// An intermediate handle representing a deferred group-by operation.
///
/// `LazyGroupBy` is produced by ``LazyDataFrame/groupBy(_:)-swift.method`` and holds
/// the upstream query plan together with the list of grouping column names. It does
/// **not** execute any grouping logic — it simply waits for the caller to choose an
/// aggregation function, at which point it constructs a `.groupBy` plan node and
/// returns a new ``LazyDataFrame``.
///
/// Each aggregation method (``sum()``, ``mean()``, ``count()``, ``min()``, ``max()``)
/// produces a ``LazyDataFrame`` whose plan contains a single `.groupBy` node. When
/// that plan is eventually executed, ``QueryExecutor`` dispatches to the eager
/// ``GroupBy`` implementation, which benefits from factorized hashing and Accelerate /
/// Metal acceleration.
///
/// ## Example
///
/// ```swift
/// let salesByRegion = df.lazy()
///     .filter(col("year") == 2025)
///     .groupBy("region")
///     .sum()         // completes the group-by, returns LazyDataFrame
///     .collect()     // materializes the result
/// ```
public struct LazyGroupBy: Sendable {

    /// The upstream query plan that feeds into the group-by.
    internal let plan: QueryPlan

    /// The column names to group by. Rows sharing the same combination of values in
    /// these columns will be collapsed into a single group during aggregation.
    internal let by: [String]

    /// Aggregate each group by computing the **sum** of all numeric columns.
    ///
    /// Non-numeric columns (other than the grouping keys) are excluded from the
    /// output. The grouping key columns appear first, followed by the summed
    /// value columns.
    ///
    /// - Returns: A ``LazyDataFrame`` with a `.groupBy(..., agg: .sum, ...)` plan node.
    public func sum() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .sum, plan))
    }

    /// Aggregate each group by computing the **arithmetic mean** of all numeric columns.
    ///
    /// - Returns: A ``LazyDataFrame`` with a `.groupBy(..., agg: .mean, ...)` plan node.
    public func mean() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .mean, plan))
    }

    /// Aggregate each group by computing the **count** of rows in each group.
    ///
    /// - Returns: A ``LazyDataFrame`` with a `.groupBy(..., agg: .count, ...)` plan node.
    public func count() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .count, plan))
    }

    /// Aggregate each group by computing the **minimum** of all numeric columns.
    ///
    /// - Returns: A ``LazyDataFrame`` with a `.groupBy(..., agg: .min, ...)` plan node.
    public func min() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .min, plan))
    }

    /// Aggregate each group by computing the **maximum** of all numeric columns.
    ///
    /// - Returns: A ``LazyDataFrame`` with a `.groupBy(..., agg: .max, ...)` plan node.
    public func max() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .max, plan))
    }
}

// MARK: - DataFrame extension

extension DataFrame {
    /// Create a lazy evaluation context for this DataFrame.
    ///
    /// Calling `.lazy()` does **not** copy the DataFrame's data. It simply wraps the
    /// receiver in a ``QueryPlan/scan(_:)`` leaf node inside a new ``LazyDataFrame``.
    /// All subsequent operations on the returned value build up a plan tree without
    /// performing any work. Call ``LazyDataFrame/collect()`` on the final lazy frame
    /// to optimize and execute the accumulated plan.
    ///
    /// ## When to Use Lazy Evaluation
    ///
    /// Lazy mode is most beneficial when you chain **multiple** operations together,
    /// because the optimizer can:
    ///
    /// - **Fuse filters**: two `.filter()` calls become one conjunctive predicate.
    /// - **Push predicates down**: filters move below sorts and group-bys so fewer
    ///   rows are processed by expensive operations.
    /// - **Push projections down**: unused columns are dropped early, reducing memory
    ///   bandwidth.
    /// - **Eliminate redundancy**: identity selects and consecutive limits are
    ///   simplified.
    ///
    /// For a single operation (e.g., just a filter), the eager path is equally
    /// efficient and avoids the small overhead of plan construction and optimization.
    ///
    /// ## Example
    ///
    /// ```swift
    /// let topCustomers = df.lazy()
    ///     .filter(col("total_spend") > 10_000)
    ///     .select("name", "total_spend", "region")
    ///     .sort(by: "total_spend", ascending: false)
    ///     .head(10)
    ///     .collect()
    /// ```
    ///
    /// - Returns: A ``LazyDataFrame`` whose plan is a `.scan` of this DataFrame.
    public func lazy() -> LazyDataFrame {
        LazyDataFrame(plan: .scan(self))
    }
}
