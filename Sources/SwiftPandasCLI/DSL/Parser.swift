import Foundation
import SwiftPandas

// MARK: - DSLParser

struct DSLParser {
    static func parse(_ input: String) throws -> [Operation] {
        let tokens = try Tokenizer(input: input).tokenize()
        if tokens.isEmpty { throw CLIError.emptyPipeline }

        // Split tokens on pipe
        let segments = splitOnPipe(tokens)
        var operations: [Operation] = []

        for segment in segments {
            if segment.isEmpty { continue }
            let op = try parseOperation(segment)
            operations.append(op)
        }

        if operations.isEmpty { throw CLIError.emptyPipeline }
        return operations
    }

    // MARK: - Pipe Splitting

    private static func splitOnPipe(_ tokens: [Token]) -> [[Token]] {
        var segments: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            if case .pipe = token {
                segments.append(current)
                current = []
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    // MARK: - Operation Dispatch

    private static func parseOperation(_ tokens: [Token]) throws -> Operation {
        guard case .identifier(let name) = tokens.first else {
            throw CLIError.malformedExpression("Expected operation name")
        }

        // Expect ( ... )
        guard tokens.count >= 3,
              case .openParen = tokens[1],
              case .closeParen = tokens.last else {
            throw CLIError.malformedExpression("Expected parentheses around arguments for '\(name)'")
        }

        let args = Array(tokens[2..<(tokens.count - 1)])

        switch name {
        case "filter":   return try parseFilter(args)
        case "sort":     return try parseSort(args)
        case "groupby":  return try parseGroupBy(args)
        case "agg":      return try parseAgg(args)
        case "select":   return try parseSelect(args)
        case "drop":     return try parseDrop(args)
        case "rename":   return try parseRename(args)
        case "head":     return try parseHead(args)
        case "tail":     return try parseTail(args)
        case "round":    return try parseRound(args)
        case "derive":   return try parseDerive(args)
        case "cast":     return try parseCast(args)
        default:
            throw CLIError.unknownOperation(name)
        }
    }

    // MARK: - Filter

    private static func parseFilter(_ args: [Token]) throws -> Operation {
        // filter(column op value) or filter(column contains "str")
        guard args.count >= 3 else {
            throw CLIError.malformedExpression("filter requires: column operator value")
        }

        guard case .identifier(let column) = args[0] else {
            throw CLIError.malformedExpression("filter: expected column name")
        }

        // Check for "contains" keyword
        if case .identifier(let keyword) = args[1], keyword == "contains" {
            let value = try parseFilterValue(Array(args[2...]))
            return .filter(FilterExpr(column: column, op: .contains, value: value))
        }

        guard case .op(let compOp) = args[1] else {
            throw CLIError.malformedExpression("filter: expected comparison operator after column name")
        }

        let filterOp: FilterOp
        switch compOp {
        case .gt: filterOp = .gt
        case .ge: filterOp = .ge
        case .lt: filterOp = .lt
        case .le: filterOp = .le
        case .eq: filterOp = .eq
        case .ne: filterOp = .ne
        }

        let value = try parseFilterValue(Array(args[2...]))
        return .filter(FilterExpr(column: column, op: filterOp, value: value))
    }

    private static func parseFilterValue(_ tokens: [Token]) throws -> FilterValue {
        guard let first = tokens.first else {
            throw CLIError.malformedExpression("filter: missing value")
        }
        switch first {
        case .number(let v): return .number(v)
        case .intNumber(let v): return .integer(v)
        case .stringLiteral(let v): return .string(v)
        case .identifier(let v):
            // Could be a bare string value
            return .string(v)
        default:
            // Check for negative number: - followed by number
            if case .arithmeticOp(.sub) = first, tokens.count >= 2 {
                switch tokens[1] {
                case .number(let v): return .number(-v)
                case .intNumber(let v): return .integer(-v)
                default: break
                }
            }
            throw CLIError.malformedExpression("filter: unexpected value token")
        }
    }

    // MARK: - Sort

    private static func parseSort(_ args: [Token]) throws -> Operation {
        // Supports: sort(col, desc), sort(col1 asc, col2 desc), sort(col)
        var specs: [SortSpec] = []
        var i = 0
        let tokens = args

        while i < tokens.count {
            guard case .identifier(let col) = tokens[i] else {
                throw CLIError.malformedExpression("sort: expected column name")
            }

            // Check if this identifier is actually a direction keyword for the previous spec
            // This shouldn't happen with the new logic, but guard anyway
            i += 1
            var dir = SortDirection.asc

            // Check next token for direction (with or without preceding comma)
            if i < tokens.count {
                // Case: sort(col asc, ...) — direction immediately after column
                if case .identifier(let dirStr) = tokens[i], SortDirection(rawValue: dirStr) != nil {
                    dir = SortDirection(rawValue: dirStr)!
                    i += 1
                }
                // Case: sort(col, desc) — comma then direction (only valid if not followed by colon which would mean agg syntax)
                else if case .comma = tokens[i],
                        i + 1 < tokens.count,
                        case .identifier(let dirStr) = tokens[i + 1],
                        let d = SortDirection(rawValue: dirStr) {
                    // Peek ahead: if this direction is the last token or followed by comma, it's a direction
                    let afterDir = i + 2
                    if afterDir >= tokens.count || tokens[afterDir] == .comma {
                        dir = d
                        i += 2 // skip comma and direction
                    }
                }
            }

            specs.append(SortSpec(column: col, direction: dir))

            // Skip comma between sort specs
            if i < tokens.count, case .comma = tokens[i] {
                i += 1
            }
        }

        if specs.isEmpty {
            throw CLIError.malformedExpression("sort: no columns specified")
        }
        return .sort(specs: specs)
    }

    // MARK: - GroupBy

    private static func parseGroupBy(_ args: [Token]) throws -> Operation {
        let columns = try parseIdentifierList(args, context: "groupby")
        return .groupBy(columns: columns)
    }

    // MARK: - Agg

    private static func parseAgg(_ args: [Token]) throws -> Operation {
        // agg(sum:revenue, mean:margin, count:transactions)
        var specs: [AggSpec] = []
        var i = 0

        while i < args.count {
            guard case .identifier(let fnName) = args[i] else {
                throw CLIError.malformedExpression("agg: expected aggregation function name")
            }
            guard let fn = AggFunc(rawValue: fnName) else {
                throw CLIError.malformedExpression("agg: unknown function '\(fnName)'. Use: sum, mean, count, min, max, std, median")
            }
            i += 1

            guard i < args.count, case .colon = args[i] else {
                throw CLIError.malformedExpression("agg: expected ':' after function name")
            }
            i += 1

            guard i < args.count, case .identifier(let col) = args[i] else {
                throw CLIError.malformedExpression("agg: expected column name after ':'")
            }
            i += 1

            specs.append(AggSpec(fn: fn, col: col))

            if i < args.count, case .comma = args[i] {
                i += 1
            }
        }

        if specs.isEmpty {
            throw CLIError.malformedExpression("agg: no aggregation specs provided")
        }
        return .aggregate(specs: specs)
    }

    // MARK: - Select / Drop

    private static func parseSelect(_ args: [Token]) throws -> Operation {
        .select(columns: try parseIdentifierList(args, context: "select"))
    }

    private static func parseDrop(_ args: [Token]) throws -> Operation {
        .drop(columns: try parseIdentifierList(args, context: "drop"))
    }

    // MARK: - Rename

    private static func parseRename(_ args: [Token]) throws -> Operation {
        // rename(old -> new)
        guard args.count >= 3,
              case .identifier(let from) = args[0],
              case .arrow = args[1],
              case .identifier(let to) = args[2] else {
            throw CLIError.malformedExpression("rename: expected 'old_name -> new_name'")
        }
        return .rename(from: from, to: to)
    }

    // MARK: - Head / Tail

    private static func parseHead(_ args: [Token]) throws -> Operation {
        .head(try parseSingleInt(args, context: "head"))
    }

    private static func parseTail(_ args: [Token]) throws -> Operation {
        .tail(try parseSingleInt(args, context: "tail"))
    }

    // MARK: - Round

    private static func parseRound(_ args: [Token]) throws -> Operation {
        // round(column, decimals)
        guard args.count >= 3,
              case .identifier(let col) = args[0],
              case .comma = args[1],
              case .intNumber(let decimals) = args[2] else {
            throw CLIError.malformedExpression("round: expected 'column, decimals'")
        }
        return .round(column: col, decimals: decimals)
    }

    // MARK: - Derive

    private static func parseDerive(_ args: [Token]) throws -> Operation {
        // derive(new_col = expr)
        guard args.count >= 3,
              case .identifier(let name) = args[0],
              case .equals = args[1] else {
            throw CLIError.malformedExpression("derive: expected 'column_name = expression'")
        }
        let exprTokens = Array(args[2...])
        let expr = try parseArithExpr(exprTokens)
        return .derive(name: name, expression: expr)
    }

    // MARK: - Cast

    private static func parseCast(_ args: [Token]) throws -> Operation {
        // cast(col, Type)
        guard args.count >= 3,
              case .identifier(let col) = args[0],
              case .comma = args[1],
              case .identifier(let typeName) = args[2] else {
            throw CLIError.malformedExpression("cast: expected 'column, Type'")
        }
        guard let target = CastTarget(rawValue: typeName) else {
            throw CLIError.invalidCastTarget(typeName)
        }
        return .cast(column: col, target: target)
    }

    // MARK: - Arithmetic Expression Parser (for derive)

    static func parseArithExpr(_ tokens: [Token]) throws -> ArithExpr {
        var pos = 0
        let result = try parseAddSub(tokens, &pos)
        if pos != tokens.count {
            throw CLIError.malformedExpression("derive: unexpected tokens after expression")
        }
        return result
    }

    // Addition/subtraction (lowest precedence)
    private static func parseAddSub(_ tokens: [Token], _ pos: inout Int) throws -> ArithExpr {
        var left = try parseMulDiv(tokens, &pos)
        while pos < tokens.count {
            if case .arithmeticOp(let op) = tokens[pos], op == .add || op == .sub {
                pos += 1
                let right = try parseMulDiv(tokens, &pos)
                left = .binary(left, op, right)
            } else {
                break
            }
        }
        return left
    }

    // Multiplication/division (higher precedence)
    private static func parseMulDiv(_ tokens: [Token], _ pos: inout Int) throws -> ArithExpr {
        var left = try parseAtom(tokens, &pos)
        while pos < tokens.count {
            if case .arithmeticOp(let op) = tokens[pos], op == .mul || op == .div {
                pos += 1
                let right = try parseAtom(tokens, &pos)
                left = .binary(left, op, right)
            } else {
                break
            }
        }
        return left
    }

    // Atoms: literals, column refs, parenthesized sub-expressions
    private static func parseAtom(_ tokens: [Token], _ pos: inout Int) throws -> ArithExpr {
        guard pos < tokens.count else {
            throw CLIError.malformedExpression("derive: unexpected end of expression")
        }

        switch tokens[pos] {
        case .number(let v):
            pos += 1
            return .literal(v)
        case .intNumber(let v):
            pos += 1
            return .literal(Double(v))
        case .stringLiteral(let v):
            pos += 1
            return .stringLiteral(v)
        case .identifier(let name):
            pos += 1
            return .columnRef(name)
        case .openParen:
            pos += 1
            let expr = try parseAddSub(tokens, &pos)
            guard pos < tokens.count, case .closeParen = tokens[pos] else {
                throw CLIError.malformedExpression("derive: expected closing parenthesis")
            }
            pos += 1
            return expr
        default:
            throw CLIError.malformedExpression("derive: unexpected token in expression")
        }
    }

    // MARK: - Helpers

    private static func parseIdentifierList(_ args: [Token], context: String) throws -> [String] {
        var names: [String] = []
        for token in args {
            switch token {
            case .identifier(let name):
                names.append(name)
            case .comma:
                continue
            default:
                throw CLIError.malformedExpression("\(context): expected column name")
            }
        }
        if names.isEmpty {
            throw CLIError.malformedExpression("\(context): no columns specified")
        }
        return names
    }

    private static func parseSingleInt(_ args: [Token], context: String) throws -> Int {
        guard args.count == 1, case .intNumber(let n) = args[0] else {
            throw CLIError.malformedExpression("\(context): expected a single integer")
        }
        return n
    }
}
