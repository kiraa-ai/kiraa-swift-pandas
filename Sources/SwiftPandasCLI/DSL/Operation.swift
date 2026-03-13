import SwiftPandas

// MARK: - Operation

enum Operation: Equatable {
    case filter(FilterExpr)
    case sort(specs: [SortSpec])
    case groupBy(columns: [String])
    case aggregate(specs: [AggSpec])
    case select(columns: [String])
    case drop(columns: [String])
    case rename(from: String, to: String)
    case head(Int)
    case tail(Int)
    case round(column: String, decimals: Int)
    case derive(name: String, expression: ArithExpr)
    case cast(column: String, target: CastTarget)
}

// MARK: - Filter Expression

struct FilterExpr: Equatable {
    let column: String
    let op: FilterOp
    let value: FilterValue
}

enum FilterOp: String, Equatable {
    case gt = ">"
    case ge = ">="
    case lt = "<"
    case le = "<="
    case eq = "=="
    case ne = "!="
    case contains = "contains"
}

enum FilterValue: Equatable {
    case number(Double)
    case integer(Int)
    case string(String)
}

// MARK: - Sort

struct SortSpec: Equatable {
    let column: String
    let direction: SortDirection
}

enum SortDirection: String, Equatable {
    case asc
    case desc
}

// MARK: - Aggregation

struct AggSpec: Equatable {
    let fn: AggFunc
    let col: String
}

enum AggFunc: String, Equatable, CaseIterable {
    case sum
    case mean
    case count
    case min
    case max
    case std
    case median
}

// MARK: - Cast

enum CastTarget: String, Equatable {
    case int = "Int"
    case double = "Double"
    case float = "Float"
    case string = "String"
}

// MARK: - Arithmetic Expression (for derive)

indirect enum ArithExpr: Equatable {
    case columnRef(String)
    case literal(Double)
    case stringLiteral(String)
    case binary(ArithExpr, ArithOp, ArithExpr)
}
