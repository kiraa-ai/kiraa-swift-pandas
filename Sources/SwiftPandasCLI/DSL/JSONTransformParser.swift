import Foundation

// MARK: - JSON Transform File Parser
//
// Parses structured .json transform files with the format:
//
// {
//   "description": "Sales summary pipeline",
//   "operations": [
//     { "op": "filter",  "args": { "column": "status", "operator": "==", "value": "active" } },
//     { "op": "groupby", "args": { "columns": ["region", "quarter"] } },
//     { "op": "agg",     "args": { "specs": [{"fn": "sum", "col": "revenue"}] } },
//     { "op": "sort",    "args": { "columns": [{"column": "revenue", "direction": "desc"}] } },
//     { "op": "rename",  "args": { "from": "revenue", "to": "total_revenue" } },
//     { "op": "round",   "args": { "column": "margin", "decimals": 3 } }
//   ]
// }

struct JSONTransformParser {

    static func parse(from jsonString: String) throws -> [Operation] {
        guard let data = jsonString.data(using: .utf8) else {
            throw CLIError.malformedExpression("Invalid UTF-8 in transform file")
        }
        return try parse(from: data)
    }

    static func parse(from data: Data) throws -> [Operation] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CLIError.malformedExpression("Invalid JSON: \(error.localizedDescription)")
        }

        guard let root = json as? [String: Any],
              let opsArray = root["operations"] as? [[String: Any]] else {
            throw CLIError.malformedExpression(
                "JSON transform file must have top-level \"operations\" array.\n" +
                errorHelpText()
            )
        }

        var operations: [Operation] = []
        for (index, opDict) in opsArray.enumerated() {
            guard let opName = opDict["op"] as? String else {
                throw CLIError.malformedExpression(
                    "Operation at index \(index) missing \"op\" field.\n" +
                    errorHelpText()
                )
            }
            guard let args = opDict["args"] as? [String: Any] else {
                throw CLIError.malformedExpression(
                    "Operation '\(opName)' at index \(index) missing \"args\" object.\n" +
                    operationHelpText(opName)
                )
            }

            do {
                let op = try parseOperation(name: opName, args: args)
                operations.append(op)
            } catch {
                throw CLIError.malformedExpression(
                    "Error in operation '\(opName)' at index \(index): \(error.localizedDescription)\n" +
                    operationHelpText(opName)
                )
            }
        }

        if operations.isEmpty { throw CLIError.emptyPipeline }
        return operations
    }

    // MARK: - Per-Operation Parsing

    private static func parseOperation(name: String, args: [String: Any]) throws -> Operation {
        switch name {
        case "filter":
            return try parseFilter(args)
        case "sort":
            return try parseSort(args)
        case "groupby":
            return try parseGroupBy(args)
        case "agg":
            return try parseAgg(args)
        case "select":
            return try parseSelect(args)
        case "drop":
            return try parseDrop(args)
        case "rename":
            return try parseRename(args)
        case "head":
            return try parseHead(args)
        case "tail":
            return try parseTail(args)
        case "round":
            return try parseRound(args)
        case "derive":
            return try parseDerive(args)
        case "cast":
            return try parseCast(args)
        default:
            throw CLIError.unknownOperation(name)
        }
    }

    // MARK: - Filter

    private static func parseFilter(_ args: [String: Any]) throws -> Operation {
        guard let column = args["column"] as? String else {
            throw CLIError.malformedExpression("filter: missing \"column\"")
        }
        guard let opStr = args["operator"] as? String else {
            throw CLIError.malformedExpression("filter: missing \"operator\"")
        }

        let filterOp: FilterOp
        switch opStr {
        case ">":        filterOp = .gt
        case ">=":       filterOp = .ge
        case "<":        filterOp = .lt
        case "<=":       filterOp = .le
        case "==":       filterOp = .eq
        case "!=":       filterOp = .ne
        case "contains": filterOp = .contains
        default:
            throw CLIError.malformedExpression("filter: unknown operator '\(opStr)'. Use: >, >=, <, <=, ==, !=, contains")
        }

        guard let rawValue = args["value"] else {
            throw CLIError.malformedExpression("filter: missing \"value\"")
        }

        let value: FilterValue
        if let s = rawValue as? String {
            value = .string(s)
        } else if let d = rawValue as? Double {
            if d == d.rounded() && d >= Double(Int.min) && d <= Double(Int.max) {
                value = .integer(Int(d))
            } else {
                value = .number(d)
            }
        } else if let i = rawValue as? Int {
            value = .integer(i)
        } else {
            throw CLIError.malformedExpression("filter: \"value\" must be a string or number")
        }

        return .filter(FilterExpr(column: column, op: filterOp, value: value))
    }

    // MARK: - Sort

    private static func parseSort(_ args: [String: Any]) throws -> Operation {
        guard let columns = args["columns"] as? [[String: Any]] else {
            throw CLIError.malformedExpression("sort: missing \"columns\" array of {column, direction}")
        }
        var specs: [SortSpec] = []
        for item in columns {
            guard let col = item["column"] as? String else {
                throw CLIError.malformedExpression("sort: each entry needs a \"column\"")
            }
            let dirStr = (item["direction"] as? String) ?? "asc"
            guard let dir = SortDirection(rawValue: dirStr) else {
                throw CLIError.malformedExpression("sort: direction must be 'asc' or 'desc'")
            }
            specs.append(SortSpec(column: col, direction: dir))
        }
        return .sort(specs: specs)
    }

    // MARK: - GroupBy

    private static func parseGroupBy(_ args: [String: Any]) throws -> Operation {
        guard let columns = args["columns"] as? [String] else {
            throw CLIError.malformedExpression("groupby: missing \"columns\" string array")
        }
        return .groupBy(columns: columns)
    }

    // MARK: - Agg

    private static func parseAgg(_ args: [String: Any]) throws -> Operation {
        guard let specs = args["specs"] as? [[String: String]] else {
            throw CLIError.malformedExpression("agg: missing \"specs\" array of {fn, col}")
        }
        var aggSpecs: [AggSpec] = []
        for item in specs {
            guard let fnStr = item["fn"], let col = item["col"] else {
                throw CLIError.malformedExpression("agg: each spec needs \"fn\" and \"col\"")
            }
            guard let fn = AggFunc(rawValue: fnStr) else {
                throw CLIError.malformedExpression("agg: unknown function '\(fnStr)'. Use: sum, mean, count, min, max, std, median")
            }
            aggSpecs.append(AggSpec(fn: fn, col: col))
        }
        return .aggregate(specs: aggSpecs)
    }

    // MARK: - Select / Drop

    private static func parseSelect(_ args: [String: Any]) throws -> Operation {
        guard let columns = args["columns"] as? [String] else {
            throw CLIError.malformedExpression("select: missing \"columns\" string array")
        }
        return .select(columns: columns)
    }

    private static func parseDrop(_ args: [String: Any]) throws -> Operation {
        guard let columns = args["columns"] as? [String] else {
            throw CLIError.malformedExpression("drop: missing \"columns\" string array")
        }
        return .drop(columns: columns)
    }

    // MARK: - Rename

    private static func parseRename(_ args: [String: Any]) throws -> Operation {
        guard let from = args["from"] as? String,
              let to = args["to"] as? String else {
            throw CLIError.malformedExpression("rename: needs \"from\" and \"to\" strings")
        }
        return .rename(from: from, to: to)
    }

    // MARK: - Head / Tail

    private static func parseHead(_ args: [String: Any]) throws -> Operation {
        guard let n = args["n"] as? Int else {
            throw CLIError.malformedExpression("head: missing integer \"n\"")
        }
        return .head(n)
    }

    private static func parseTail(_ args: [String: Any]) throws -> Operation {
        guard let n = args["n"] as? Int else {
            throw CLIError.malformedExpression("tail: missing integer \"n\"")
        }
        return .tail(n)
    }

    // MARK: - Round

    private static func parseRound(_ args: [String: Any]) throws -> Operation {
        guard let column = args["column"] as? String,
              let decimals = args["decimals"] as? Int else {
            throw CLIError.malformedExpression("round: needs \"column\" and \"decimals\"")
        }
        return .round(column: column, decimals: decimals)
    }

    // MARK: - Derive

    private static func parseDerive(_ args: [String: Any]) throws -> Operation {
        guard let name = args["name"] as? String,
              let exprStr = args["expression"] as? String else {
            throw CLIError.malformedExpression("derive: needs \"name\" and \"expression\"")
        }
        let tokens = try Tokenizer(input: exprStr).tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        return .derive(name: name, expression: expr)
    }

    // MARK: - Cast

    private static func parseCast(_ args: [String: Any]) throws -> Operation {
        guard let column = args["column"] as? String,
              let typeStr = args["type"] as? String else {
            throw CLIError.malformedExpression("cast: needs \"column\" and \"type\"")
        }
        guard let target = CastTarget(rawValue: typeStr) else {
            throw CLIError.invalidCastTarget(typeStr)
        }
        return .cast(column: column, target: target)
    }

    // MARK: - Error Help

    static func errorHelpText() -> String {
        return """

        JSON Transform File Format
        ==========================
        {
          "description": "Optional description of this pipeline",
          "operations": [
            { "op": "<operation_name>", "args": { ... } },
            ...
          ]
        }

        Available operations: filter, groupby, agg, sort, rename, round,
                              derive, select, drop, head, tail, cast

        Run with --help-ops for detailed argument schemas per operation.
        """
    }

    static func operationHelpText(_ opName: String) -> String {
        switch opName {
        case "filter":
            return """
            filter: { "column": "col_name", "operator": ">|>=|<|<=|==|!=|contains", "value": <string|number> }
              Example: { "op": "filter", "args": { "column": "revenue", "operator": ">", "value": 10000 } }
              Example: { "op": "filter", "args": { "column": "status", "operator": "==", "value": "active" } }
            """
        case "sort":
            return """
            sort: { "columns": [{ "column": "col_name", "direction": "asc|desc" }, ...] }
              Example: { "op": "sort", "args": { "columns": [{"column": "revenue", "direction": "desc"}] } }
            """
        case "groupby":
            return """
            groupby: { "columns": ["col1", "col2", ...] }
              Must be followed by an "agg" operation.
              Example: { "op": "groupby", "args": { "columns": ["region", "quarter"] } }
            """
        case "agg":
            return """
            agg: { "specs": [{ "fn": "sum|mean|count|min|max|std|median", "col": "col_name" }, ...] }
              Must follow a "groupby" operation.
              Example: { "op": "agg", "args": { "specs": [{"fn": "sum", "col": "revenue"}, {"fn": "mean", "col": "margin"}] } }
            """
        case "select":
            return """
            select: { "columns": ["col1", "col2", ...] }
              Example: { "op": "select", "args": { "columns": ["region", "revenue", "margin"] } }
            """
        case "drop":
            return """
            drop: { "columns": ["col1", "col2", ...] }
              Example: { "op": "drop", "args": { "columns": ["cost", "status"] } }
            """
        case "rename":
            return """
            rename: { "from": "old_name", "to": "new_name" }
              Example: { "op": "rename", "args": { "from": "revenue", "to": "total_revenue" } }
            """
        case "head":
            return """
            head: { "n": <integer> }
              Example: { "op": "head", "args": { "n": 10 } }
            """
        case "tail":
            return """
            tail: { "n": <integer> }
              Example: { "op": "tail", "args": { "n": 5 } }
            """
        case "round":
            return """
            round: { "column": "col_name", "decimals": <integer> }
              Example: { "op": "round", "args": { "column": "margin", "decimals": 2 } }
            """
        case "derive":
            return """
            derive: { "name": "new_col_name", "expression": "arithmetic expression" }
              Supports: +, -, *, / with column names and numeric literals.
              Example: { "op": "derive", "args": { "name": "profit", "expression": "revenue - cost" } }
            """
        case "cast":
            return """
            cast: { "column": "col_name", "type": "Int|Double|Float|String" }
              Example: { "op": "cast", "args": { "column": "transactions", "type": "Int" } }
            """
        default:
            return "Unknown operation '\(opName)'. Valid: filter, groupby, agg, sort, rename, round, derive, select, drop, head, tail, cast"
        }
    }
}
