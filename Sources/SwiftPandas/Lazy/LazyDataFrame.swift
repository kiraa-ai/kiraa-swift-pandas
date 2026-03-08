/// A lazily-evaluated DataFrame that builds a query plan instead of materializing data.
///
/// Operations on LazyDataFrame return new LazyDataFrame instances with extended
/// query plans. No computation happens until `.collect()` is called, at which
/// point the plan is optimized and executed.
///
/// ```swift
/// let result = df.lazy()
///     .filter(col("revenue") > 1000)
///     .select("name", "region", "revenue")
///     .groupBy("region").sum()
///     .collect()
/// ```
public struct LazyDataFrame: Sendable {
    internal let plan: QueryPlan

    internal init(plan: QueryPlan) {
        self.plan = plan
    }

    /// Execute the query plan: optimize, then execute, returning a materialized DataFrame.
    public func collect() -> DataFrame {
        let optimized = QueryOptimizer.optimize(plan)
        return QueryExecutor.execute(optimized)
    }

    // MARK: - Operations

    /// Filter rows matching a predicate.
    public func filter(_ predicate: ColumnPredicate) -> LazyDataFrame {
        LazyDataFrame(plan: .filter(predicate, plan))
    }

    /// Select specific columns.
    public func select(_ columns: [String]) -> LazyDataFrame {
        LazyDataFrame(plan: .select(columns, plan))
    }

    /// Select specific columns (variadic).
    public func select(_ columns: String...) -> LazyDataFrame {
        select(columns)
    }

    /// Drop specific columns.
    public func drop(_ columns: [String]) -> LazyDataFrame {
        guard let current = plan.outputColumns else { return self }
        let remaining = current.filter { !columns.contains($0) }
        return select(remaining)
    }

    /// Sort by multiple columns.
    public func sort(by columns: [String], ascending: [Bool]? = nil) -> LazyDataFrame {
        let asc = ascending ?? [Bool](repeating: true, count: columns.count)
        return LazyDataFrame(plan: .sort(by: columns, ascending: asc, plan))
    }

    /// Sort by a single column.
    public func sort(by column: String, ascending: Bool = true) -> LazyDataFrame {
        sort(by: [column], ascending: [ascending])
    }

    /// Take first N rows.
    public func head(_ n: Int) -> LazyDataFrame {
        LazyDataFrame(plan: .limit(n, plan))
    }

    /// Group by columns (variadic).
    public func groupBy(_ columns: String...) -> LazyGroupBy {
        LazyGroupBy(plan: plan, by: columns)
    }

    /// Group by columns (array).
    public func groupBy(_ columns: [String]) -> LazyGroupBy {
        LazyGroupBy(plan: plan, by: columns)
    }

    /// Merge with another LazyDataFrame on a key column.
    public func merge(_ other: LazyDataFrame, on key: String, how: MergeHow = .inner) -> LazyDataFrame {
        LazyDataFrame(plan: .join(left: plan, right: other.plan, on: key, how: how))
    }

    // MARK: - Explain

    /// Pretty-print the optimized query plan for debugging.
    public func explain() -> String {
        let optimized = QueryOptimizer.optimize(plan)
        return "Optimized Plan:\n\(optimized.description)"
    }

    /// Pretty-print the raw (unoptimized) query plan.
    public func explainRaw() -> String {
        "Raw Plan:\n\(plan.description)"
    }
}

// MARK: - LazyGroupBy

/// Lazy GroupBy that defers aggregation until collect().
public struct LazyGroupBy: Sendable {
    internal let plan: QueryPlan
    internal let by: [String]

    public func sum() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .sum, plan))
    }

    public func mean() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .mean, plan))
    }

    public func count() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .count, plan))
    }

    public func min() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .min, plan))
    }

    public func max() -> LazyDataFrame {
        LazyDataFrame(plan: .groupBy(by: by, agg: .max, plan))
    }
}

// MARK: - DataFrame extension

extension DataFrame {
    /// Create a lazy evaluation context for this DataFrame.
    ///
    /// Operations on the returned LazyDataFrame build a query plan instead
    /// of materializing intermediate results. Call `.collect()` to execute.
    public func lazy() -> LazyDataFrame {
        LazyDataFrame(plan: .scan(self))
    }
}
