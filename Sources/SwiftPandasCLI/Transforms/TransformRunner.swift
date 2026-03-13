import Foundation
import SwiftPandas

struct TransformRunner {
    let operations: [Operation]
    let verbose: Bool

    func run(on df: DataFrame) throws -> DataFrame {
        var current = df
        var pendingGroupBy: [String]? = nil
        var stepIndex = 0

        for (i, op) in operations.enumerated() {
            stepIndex = i + 1

            // Handle groupby + agg pairing
            if case .groupBy(let columns) = op {
                pendingGroupBy = columns
                if verbose {
                    logStep(stepIndex, name: "groupby", detail: columns.joined(separator: ", "),
                            rows: current.rowCount, cols: current.columnCount,
                            note: "pending agg", elapsed: 0)
                }
                continue
            }

            if case .aggregate(let specs) = op {
                guard let groupColumns = pendingGroupBy else {
                    throw CLIError.aggWithoutGroupBy
                }
                let start = CFAbsoluteTimeGetCurrent()
                current = try applyGroupByAgg(df: current, groupColumns: groupColumns, specs: specs)
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                pendingGroupBy = nil
                if verbose {
                    let detail = specs.map { "\($0.fn.rawValue):\($0.col)" }.joined(separator: ", ")
                    logStep(stepIndex, name: "agg", detail: detail,
                            rows: current.rowCount, cols: current.columnCount, elapsed: elapsed)
                }
                continue
            }

            // If we had a pending groupby but the next op is not agg, error
            if pendingGroupBy != nil {
                throw CLIError.aggWithoutGroupBy
            }

            let start = CFAbsoluteTimeGetCurrent()
            current = try apply(op, to: current)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            if verbose {
                let name = operationName(op)
                let detail = operationDetail(op)
                logStep(stepIndex, name: name, detail: detail,
                        rows: current.rowCount, cols: current.columnCount, elapsed: elapsed)
            }
        }

        // If pipeline ends with groupby (no agg), default to count
        if let groupColumns = pendingGroupBy {
            let start = CFAbsoluteTimeGetCurrent()
            let gb = current.groupBy(groupColumns)
            current = gb.count()
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            if verbose {
                logStep(stepIndex + 1, name: "count", detail: "default",
                        rows: current.rowCount, cols: current.columnCount, elapsed: elapsed)
            }
        }

        return current
    }

    // MARK: - Apply Single Operation

    private func apply(_ op: Operation, to df: DataFrame) throws -> DataFrame {
        switch op {
        case .filter(let expr):
            return try applyFilter(df: df, expr: expr)

        case .sort(let specs):
            let columns = specs.map { $0.column }
            let ascending = specs.map { $0.direction == .asc }
            // Validate columns exist
            for col in columns {
                if !df.columnNames.contains(col) {
                    throw CLIError.unknownColumn(col)
                }
            }
            if columns.count == 1 {
                return df.sortValues(by: columns[0], ascending: ascending[0])
            }
            return df.sortValues(by: columns, ascending: ascending)

        case .select(let columns):
            for col in columns {
                if !df.columnNames.contains(col) {
                    throw CLIError.unknownColumn(col)
                }
            }
            return df.select(columns: columns)

        case .drop(let columns):
            for col in columns {
                if !df.columnNames.contains(col) {
                    throw CLIError.unknownColumn(col)
                }
            }
            return df.drop(columns: columns)

        case .rename(let from, let to):
            if !df.columnNames.contains(from) {
                throw CLIError.unknownColumn(from)
            }
            return df.rename(columns: [from: to])

        case .head(let n):
            return df.head(min(n, df.rowCount))

        case .tail(let n):
            return df.tail(min(n, df.rowCount))

        case .round(let column, let decimals):
            return try applyRound(df: df, column: column, decimals: decimals)

        case .derive(let name, let expression):
            return try applyDerive(df: df, name: name, expression: expression)

        case .cast(let column, let target):
            return try applyCast(df: df, column: column, target: target)

        case .groupBy, .aggregate:
            // Handled in run() loop
            fatalError("groupBy/aggregate should not reach apply()")
        }
    }

    // MARK: - Filter

    private func applyFilter(df: DataFrame, expr: FilterExpr) throws -> DataFrame {
        if !df.columnNames.contains(expr.column) {
            throw CLIError.unknownColumn(expr.column)
        }

        let predicate: ColumnPredicate
        switch expr.op {
        case .contains:
            guard case .string(let sub) = expr.value else {
                throw CLIError.typeMismatch(column: expr.column, expected: "String", got: "number")
            }
            predicate = .stringContains(column: expr.column, substring: sub)

        default:
            let compOp: CompOp
            switch expr.op {
            case .gt: compOp = .gt
            case .ge: compOp = .ge
            case .lt: compOp = .lt
            case .le: compOp = .le
            case .eq: compOp = .eq
            case .ne: compOp = .ne
            case .contains: fatalError("handled above")
            }

            let predValue: PredicateValue
            switch expr.value {
            case .number(let v): predValue = .double(v)
            case .integer(let v): predValue = .int64(Int64(v))
            case .string(let v): predValue = .string(v)
            }

            predicate = .comparison(column: expr.column, op: compOp, value: predValue)
        }

        let mask = predicate.evaluate(on: df)
        return df.filter(mask: mask)
    }

    // MARK: - GroupBy + Agg

    private func applyGroupByAgg(df: DataFrame, groupColumns: [String], specs: [AggSpec]) throws -> DataFrame {
        // Validate group columns
        for col in groupColumns {
            if !df.columnNames.contains(col) {
                throw CLIError.unknownColumn(col)
            }
        }
        // Validate agg columns
        for spec in specs {
            if !df.columnNames.contains(spec.col) {
                throw CLIError.unknownColumn(spec.col)
            }
        }

        let gb = df.groupBy(groupColumns)

        // Cache aggregation results by function to avoid redundant computation
        var cache: [AggFunc: DataFrame] = [:]
        func getAggResult(_ fn: AggFunc) -> DataFrame {
            if let cached = cache[fn] { return cached }
            let result: DataFrame
            switch fn {
            case .sum:    result = gb.sum()
            case .mean:   result = gb.mean()
            case .count:  result = gb.count()
            case .min:    result = gb.min()
            case .max:    result = gb.max()
            case .std:    result = gb.mean() // fallback
            case .median: result = gb.mean() // fallback
            }
            cache[fn] = result
            return result
        }

        // Get any aggregation result to extract structure
        let firstResult = getAggResult(specs[0].fn)

        // Build result DataFrame with key columns + value columns
        // For single-key groupby, the library puts the key in the index, not as a column.
        // For multi-key groupby, keys are regular columns.
        var resultPairs: [(String, Column)] = []

        if groupColumns.count == 1 {
            // Single-key: reconstruct key column from the index
            let keyCol = groupColumns[0]
            let indexLabels = firstResult.indexLabels
            resultPairs.append((keyCol, Column.fromStrings(indexLabels)))
        } else {
            // Multi-key: keys are already columns in the result
            for keyCol in groupColumns {
                resultPairs.append((keyCol, firstResult[keyCol].data))
            }
        }

        // Add each requested value column from its corresponding aggregation
        for spec in specs {
            let aggResult = getAggResult(spec.fn)
            resultPairs.append((spec.col, aggResult[spec.col].data))
        }

        return DataFrame(columns: resultPairs)
    }

    // MARK: - Round

    private func applyRound(df: DataFrame, column: String, decimals: Int) throws -> DataFrame {
        if !df.columnNames.contains(column) {
            throw CLIError.unknownColumn(column)
        }

        let series = df[column]
        let multiplier = pow(10.0, Double(decimals))
        let rounded = series.apply { ($0 * multiplier).rounded() / multiplier }

        var result = df
        result[column] = rounded
        return result
    }

    // MARK: - Derive

    private func applyDerive(df: DataFrame, name: String, expression: ArithExpr) throws -> DataFrame {
        let resultSeries = try evaluateArithExpr(expression, on: df, name: name)
        var result = df
        result[name] = resultSeries
        return result
    }

    private func evaluateArithExpr(_ expr: ArithExpr, on df: DataFrame, name: String) throws -> Series {
        switch expr {
        case .columnRef(let col):
            if !df.columnNames.contains(col) {
                throw CLIError.unknownColumn(col)
            }
            return df[col]

        case .literal(let v):
            // Create a Series of constant values matching df row count
            let values = [Double](repeating: v, count: df.rowCount)
            return Series(values, name: name)

        case .stringLiteral(let v):
            let values = [String](repeating: v, count: df.rowCount)
            return Series(values, name: name)

        case .binary(let lhs, let op, let rhs):
            let left = try evaluateArithExpr(lhs, on: df, name: name)
            let right = try evaluateArithExpr(rhs, on: df, name: name)

            switch op {
            case .add: return left + right
            case .sub: return left - right
            case .mul: return left * right
            case .div: return left / right
            }
        }
    }

    // MARK: - Cast

    private func applyCast(df: DataFrame, column: String, target: CastTarget) throws -> DataFrame {
        if !df.columnNames.contains(column) {
            throw CLIError.unknownColumn(column)
        }

        let series = df[column]
        let n = series.count
        let newCol: Column

        switch target {
        case .double, .float:
            // Try numeric conversion first, fall back to string parsing
            if series.isNumeric {
                newCol = series.data // already numeric
            } else {
                var values: [Double?] = []
                for i in 0..<n {
                    if let v = series[i] as? String, let d = Double(v) {
                        values.append(d)
                    } else if let v = series[i] as? Double {
                        values.append(v)
                    } else {
                        values.append(nil)
                    }
                }
                newCol = Column.fromOptionalDoubles(values)
            }

        case .int:
            var values: [Int?] = []
            for i in 0..<n {
                if let v = series[i] as? Double {
                    values.append(Int(v))
                } else if let v = series[i] as? String, let d = Double(v) {
                    values.append(Int(d))
                } else {
                    values.append(nil)
                }
            }
            newCol = Column.fromOptionalInts(values)

        case .string:
            var values: [String?] = []
            for i in 0..<n {
                if let v = series[i] {
                    values.append("\(v)")
                } else {
                    values.append(nil)
                }
            }
            newCol = Column.fromOptionalStrings(values)
        }

        var result = df
        result[column] = Series(data: newCol, name: column)
        return result
    }

    // MARK: - Logging

    private func logStep(_ step: Int, name: String, detail: String,
                          rows: Int, cols: Int, note: String? = nil, elapsed: Double) {
        let num = String(format: "%2d", step)
        let padName = name.padding(toLength: 8, withPad: " ", startingAt: 0)
        let timeStr = formatTime(elapsed)
        var line = "  \(Style.dim)\(num).\(Style.reset) \(Style.magenta)\(padName)\(Style.reset)"
        line += "\(Style.dim)│\(Style.reset) \(detail)"
        if let n = note {
            line += " \(Style.dim)(\(n))\(Style.reset)"
        }
        line += "\n           \(Style.dim)│\(Style.reset) → \(formatCount(rows)) rows × \(formatCount(cols)) cols  \(Style.dim)\(timeStr)\(Style.reset)"
        logStderr(line)
    }

    private func logStderr(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }

    private func formatTime(_ seconds: Double) -> String {
        if seconds < 0.001 {
            return String(format: "%.0fµs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.1fms", seconds * 1_000)
        } else {
            return String(format: "%.2fs", seconds)
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 10_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private func operationName(_ op: Operation) -> String {
        switch op {
        case .filter: return "filter"
        case .sort: return "sort"
        case .select: return "select"
        case .drop: return "drop"
        case .rename: return "rename"
        case .head: return "head"
        case .tail: return "tail"
        case .round: return "round"
        case .derive: return "derive"
        case .cast: return "cast"
        case .groupBy: return "groupby"
        case .aggregate: return "agg"
        }
    }

    private func operationDetail(_ op: Operation) -> String {
        switch op {
        case .filter(let expr):
            let valStr: String
            switch expr.value {
            case .number(let v): valStr = "\(v)"
            case .integer(let v): valStr = "\(v)"
            case .string(let v): valStr = "\"\(v)\""
            }
            return "\(expr.column) \(expr.op.rawValue) \(valStr)"
        case .sort(let specs):
            return specs.map { "\($0.column) \($0.direction.rawValue)" }.joined(separator: ", ")
        case .select(let cols), .drop(let cols):
            return cols.joined(separator: ", ")
        case .rename(let from, let to):
            return "\(from) → \(to)"
        case .head(let n):
            return "\(n)"
        case .tail(let n):
            return "\(n)"
        case .round(let col, let d):
            return "\(col) to \(d) decimals"
        case .derive(let name, _):
            return name
        case .cast(let col, let target):
            return "\(col) → \(target.rawValue)"
        case .groupBy(let cols):
            return cols.joined(separator: ", ")
        case .aggregate(let specs):
            return specs.map { "\($0.fn.rawValue):\($0.col)" }.joined(separator: ", ")
        }
    }
}
