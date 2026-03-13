import XCTest
@testable import SwiftPandasCLI

final class ParserTests: XCTestCase {

    // MARK: - Tokenizer

    func test_tokenize_simple() throws {
        let tokens = try Tokenizer(input: "filter(revenue > 10000)").tokenize()
        XCTAssertEqual(tokens, [
            .identifier("filter"), .openParen,
            .identifier("revenue"), .op(.gt), .intNumber(10000),
            .closeParen
        ])
    }

    func test_tokenize_stringLiteral() throws {
        let tokens = try Tokenizer(input: "filter(status == \"active\")").tokenize()
        XCTAssertEqual(tokens, [
            .identifier("filter"), .openParen,
            .identifier("status"), .op(.eq), .stringLiteral("active"),
            .closeParen
        ])
    }

    func test_tokenize_pipe() throws {
        let tokens = try Tokenizer(input: "head(5) | tail(3)").tokenize()
        XCTAssert(tokens.contains(.pipe))
    }

    func test_tokenize_arrow() throws {
        let tokens = try Tokenizer(input: "rename(old -> new)").tokenize()
        XCTAssert(tokens.contains(.arrow))
    }

    func test_tokenize_colon() throws {
        let tokens = try Tokenizer(input: "agg(sum:revenue)").tokenize()
        XCTAssert(tokens.contains(.colon))
    }

    func test_tokenize_floatNumber() throws {
        let tokens = try Tokenizer(input: "filter(margin > 0.15)").tokenize()
        // tokens: filter ( margin > 0.15 )  — index 4 is the number
        XCTAssertEqual(tokens[4], .number(0.15))
    }

    func test_tokenize_negativeNumber() throws {
        let tokens = try Tokenizer(input: "filter(profit > -500)").tokenize()
        // tokens: filter ( profit > -500 )  — index 4 is the negative number
        XCTAssertEqual(tokens[4], .intNumber(-500))
    }

    func test_tokenize_comment() throws {
        let tokens = try Tokenizer(input: "# comment\nhead(5)").tokenize()
        XCTAssertEqual(tokens, [
            .identifier("head"), .openParen, .intNumber(5), .closeParen
        ])
    }

    // MARK: - DSL Parser: Single Operations

    func test_parse_filter_greaterThan() throws {
        let ops = try DSLParser.parse("filter(revenue > 10000)")
        XCTAssertEqual(ops.count, 1)
        guard case .filter(let expr) = ops[0] else { return XCTFail("Expected filter") }
        XCTAssertEqual(expr.column, "revenue")
        XCTAssertEqual(expr.op, .gt)
        XCTAssertEqual(expr.value, .integer(10000))
    }

    func test_parse_filter_stringEquality() throws {
        let ops = try DSLParser.parse("filter(status == \"active\")")
        guard case .filter(let expr) = ops[0] else { return XCTFail() }
        XCTAssertEqual(expr.op, .eq)
        XCTAssertEqual(expr.value, .string("active"))
    }

    func test_parse_filter_contains() throws {
        let ops = try DSLParser.parse("filter(sku contains \"001\")")
        guard case .filter(let expr) = ops[0] else { return XCTFail() }
        XCTAssertEqual(expr.op, .contains)
        XCTAssertEqual(expr.value, .string("001"))
    }

    func test_parse_sort_desc() throws {
        let ops = try DSLParser.parse("sort(revenue, desc)")
        guard case .sort(let specs) = ops[0] else { return XCTFail() }
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0].column, "revenue")
        XCTAssertEqual(specs[0].direction, .desc)
    }

    func test_parse_sort_multiColumn() throws {
        let ops = try DSLParser.parse("sort(region asc, revenue desc)")
        guard case .sort(let specs) = ops[0] else { return XCTFail() }
        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].direction, .asc)
        XCTAssertEqual(specs[1].direction, .desc)
    }

    func test_parse_groupby() throws {
        let ops = try DSLParser.parse("groupby(region, quarter)")
        guard case .groupBy(let cols) = ops[0] else { return XCTFail() }
        XCTAssertEqual(cols, ["region", "quarter"])
    }

    func test_parse_agg() throws {
        let ops = try DSLParser.parse("agg(sum:revenue, mean:margin, count:transactions)")
        guard case .aggregate(let specs) = ops[0] else { return XCTFail() }
        XCTAssertEqual(specs.count, 3)
        XCTAssertEqual(specs[0].fn, .sum)
        XCTAssertEqual(specs[0].col, "revenue")
        XCTAssertEqual(specs[1].fn, .mean)
        XCTAssertEqual(specs[2].fn, .count)
    }

    func test_parse_select() throws {
        let ops = try DSLParser.parse("select(region, revenue)")
        guard case .select(let cols) = ops[0] else { return XCTFail() }
        XCTAssertEqual(cols, ["region", "revenue"])
    }

    func test_parse_drop() throws {
        let ops = try DSLParser.parse("drop(cost, status)")
        guard case .drop(let cols) = ops[0] else { return XCTFail() }
        XCTAssertEqual(cols, ["cost", "status"])
    }

    func test_parse_rename() throws {
        let ops = try DSLParser.parse("rename(revenue -> total_revenue)")
        guard case .rename(let from, let to) = ops[0] else { return XCTFail() }
        XCTAssertEqual(from, "revenue")
        XCTAssertEqual(to, "total_revenue")
    }

    func test_parse_head() throws {
        let ops = try DSLParser.parse("head(5)")
        guard case .head(let n) = ops[0] else { return XCTFail() }
        XCTAssertEqual(n, 5)
    }

    func test_parse_tail() throws {
        let ops = try DSLParser.parse("tail(3)")
        guard case .tail(let n) = ops[0] else { return XCTFail() }
        XCTAssertEqual(n, 3)
    }

    func test_parse_round() throws {
        let ops = try DSLParser.parse("round(margin, 2)")
        guard case .round(let col, let d) = ops[0] else { return XCTFail() }
        XCTAssertEqual(col, "margin")
        XCTAssertEqual(d, 2)
    }

    func test_parse_derive() throws {
        let ops = try DSLParser.parse("derive(profit = revenue - cost)")
        guard case .derive(let name, let expr) = ops[0] else { return XCTFail() }
        XCTAssertEqual(name, "profit")
        if case .binary(let lhs, let op, let rhs) = expr {
            XCTAssertEqual(lhs, .columnRef("revenue"))
            XCTAssertEqual(op, .sub)
            XCTAssertEqual(rhs, .columnRef("cost"))
        } else {
            XCTFail("Expected binary expression")
        }
    }

    func test_parse_cast() throws {
        let ops = try DSLParser.parse("cast(transactions, Int)")
        guard case .cast(let col, let target) = ops[0] else { return XCTFail() }
        XCTAssertEqual(col, "transactions")
        XCTAssertEqual(target, .int)
    }

    // MARK: - Chains

    func test_parse_chainOfThree() throws {
        let ops = try DSLParser.parse("filter(revenue > 0) | sort(revenue, desc) | head(5)")
        XCTAssertEqual(ops.count, 3)
    }

    func test_parse_multilineChain() throws {
        let raw = """
          filter(status == "active") |
          groupby(region)            |
          agg(sum:revenue)
        """
        let ops = try DSLParser.parse(raw)
        XCTAssertEqual(ops.count, 3)
    }

    // MARK: - Error Cases

    func test_unknownOperation_throws() throws {
        XCTAssertThrowsError(try DSLParser.parse("explode(col)")) { error in
            guard let e = error as? CLIError, case .unknownOperation(let name) = e else {
                return XCTFail("Wrong error type: \(error)")
            }
            XCTAssertEqual(name, "explode")
        }
    }

    func test_malformedParens_throws() throws {
        XCTAssertThrowsError(try DSLParser.parse("filter(revenue > 10000"))
    }

    func test_emptyInput_throws() throws {
        XCTAssertThrowsError(try DSLParser.parse(""))
    }

    // MARK: - Arithmetic Expression Parser

    func test_arithExpr_simple() throws {
        let tokens = try Tokenizer(input: "revenue - cost").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        XCTAssertEqual(expr, .binary(.columnRef("revenue"), .sub, .columnRef("cost")))
    }

    func test_arithExpr_precedence() throws {
        // a + b * c should parse as a + (b * c)
        let tokens = try Tokenizer(input: "a + b * c").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        if case .binary(let lhs, .add, let rhs) = expr {
            XCTAssertEqual(lhs, .columnRef("a"))
            if case .binary(.columnRef("b"), .mul, .columnRef("c")) = rhs {
                // OK
            } else {
                XCTFail("Expected b * c on right side")
            }
        } else {
            XCTFail("Expected addition at top level")
        }
    }

    func test_arithExpr_literal() throws {
        let tokens = try Tokenizer(input: "revenue * 100").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        XCTAssertEqual(expr, .binary(.columnRef("revenue"), .mul, .literal(100.0)))
    }

    // MARK: - JSON Transform Parser

    func test_jsonParser_filter() throws {
        let json = """
        {
          "operations": [
            { "op": "filter", "args": { "column": "revenue", "operator": ">", "value": 10000 } }
          ]
        }
        """
        let ops = try JSONTransformParser.parse(from: json)
        XCTAssertEqual(ops.count, 1)
        guard case .filter(let expr) = ops[0] else { return XCTFail() }
        XCTAssertEqual(expr.column, "revenue")
        XCTAssertEqual(expr.op, .gt)
    }

    func test_jsonParser_fullPipeline() throws {
        let json = """
        {
          "description": "test",
          "operations": [
            { "op": "filter",  "args": { "column": "status", "operator": "==", "value": "active" } },
            { "op": "groupby", "args": { "columns": ["region"] } },
            { "op": "agg",     "args": { "specs": [{"fn": "sum", "col": "revenue"}] } },
            { "op": "sort",    "args": { "columns": [{"column": "revenue", "direction": "desc"}] } }
          ]
        }
        """
        let ops = try JSONTransformParser.parse(from: json)
        XCTAssertEqual(ops.count, 4)
    }

    func test_jsonParser_invalidJSON_throws() throws {
        XCTAssertThrowsError(try JSONTransformParser.parse(from: "not json"))
    }

    func test_jsonParser_missingOperations_throws() throws {
        XCTAssertThrowsError(try JSONTransformParser.parse(from: "{}"))
    }

    func test_jsonParser_unknownOp_throws() throws {
        let json = """
        { "operations": [{ "op": "explode", "args": {} }] }
        """
        XCTAssertThrowsError(try JSONTransformParser.parse(from: json))
    }

    func test_jsonParser_missingArgs_throws() throws {
        let json = """
        { "operations": [{ "op": "filter" }] }
        """
        XCTAssertThrowsError(try JSONTransformParser.parse(from: json))
    }
}
