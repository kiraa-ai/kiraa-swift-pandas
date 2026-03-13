import Foundation

public enum CLIError: Error, LocalizedError {
    case unknownOperation(String)
    case malformedExpression(String)
    case unknownColumn(String)
    case typeMismatch(column: String, expected: String, got: String)
    case divisionByZero
    case invalidCastTarget(String)
    case aggWithoutGroupBy
    case noTransformProvided
    case fileNotFound(String)
    case emptyPipeline

    public var errorDescription: String? {
        switch self {
        case .unknownOperation(let name):
            return "Unknown operation '\(name)'. Valid: filter, groupby, agg, sort, rename, round, derive, select, drop, head, tail, cast"
        case .malformedExpression(let expr):
            return "Could not parse expression: '\(expr)'"
        case .unknownColumn(let col):
            return "Column '\(col)' not found in dataframe"
        case .typeMismatch(let col, let expected, let got):
            return "Column '\(col)': expected \(expected), got \(got)"
        case .divisionByZero:
            return "Division by zero in derive expression"
        case .invalidCastTarget(let t):
            return "Unknown cast target '\(t)'. Use: Int, Double, String"
        case .aggWithoutGroupBy:
            return "agg() must follow a groupby() operation"
        case .noTransformProvided:
            return "Provide either --chain (-c) or --file (-f)"
        case .fileNotFound(let path):
            return "File not found: '\(path)'"
        case .emptyPipeline:
            return "Transform chain is empty"
        }
    }

    public var isUnknownColumn: Bool {
        if case .unknownColumn = self { return true }
        return false
    }
}
