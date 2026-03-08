/// Executes an optimized query plan by dispatching to eager DataFrame operations.
///
/// The executor recursively walks the plan tree bottom-up, materializing
/// each node using the existing DataFrame methods. This means we get all
/// existing optimizations (vDSP, Metal GPU, factorized groupBy) for free.
public enum QueryExecutor {

    /// Execute a query plan and return the materialized DataFrame.
    public static func execute(_ plan: QueryPlan) -> DataFrame {
        switch plan {
        case .scan(let df):
            return df

        case .filter(let predicate, let source):
            let df = execute(source)
            let mask = predicate.evaluate(on: df)
            return df.filter(mask: mask)

        case .select(let columns, let source):
            let df = execute(source)
            return df.select(columns: columns)

        case .groupBy(let by, let agg, let source):
            let df = execute(source)
            let gb: GroupBy
            if by.count == 1 {
                gb = df.groupBy(by[0])
            } else {
                gb = df.groupBy(by)
            }
            switch agg {
            case .sum: return gb.sum()
            case .mean: return gb.mean()
            case .count: return gb.count()
            case .min: return gb.min()
            case .max: return gb.max()
            }

        case .sort(let by, let asc, let source):
            let df = execute(source)
            return df.sortValues(by: by, ascending: asc)

        case .join(let left, let right, let key, let how):
            let leftDF = execute(left)
            let rightDF = execute(right)
            return leftDF.merge(rightDF, on: key, how: how)

        case .limit(let n, let source):
            let df = execute(source)
            return df.head(n)
        }
    }
}
