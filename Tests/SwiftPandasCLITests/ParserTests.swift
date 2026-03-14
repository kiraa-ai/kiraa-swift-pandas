import Testing
@testable import SwiftPandasCLI

@Suite struct ParserTests {

    // MARK: - Tokenizer

    @Test func test_tokenize_simple() throws {
        let tokens = try Tokenizer(input: "filter(revenue > 10000)").tokenize()
        #expect(tokens == [
            .identifier("filter"), .openParen,
            .identifier("revenue"), .op(.gt), .intNumber(10000),
            .closeParen
        ])
    }

    @Test func test_tokenize_stringLiteral() throws {
        let tokens = try Tokenizer(input: "filter(status == \"active\")").tokenize()
        #expect(tokens == [
            .identifier("filter"), .openParen,
            .identifier("status"), .op(.eq), .stringLiteral("active"),
            .closeParen
        ])
    }

    @Test func test_tokenize_pipe() throws {
        let tokens = try Tokenizer(input: "head(5) | tail(3)").tokenize()
        #expect(tokens.contains(.pipe))
    }

    @Test func test_tokenize_arrow() throws {
        let tokens = try Tokenizer(input: "rename(old -> new)").tokenize()
        #expect(tokens.contains(.arrow))
    }

    @Test func test_tokenize_colon() throws {
        let tokens = try Tokenizer(input: "agg(sum:revenue)").tokenize()
        #expect(tokens.contains(.colon))
    }

    @Test func test_tokenize_floatNumber() throws {
        let tokens = try Tokenizer(input: "filter(margin > 0.15)").tokenize()
        // tokens: filter ( margin > 0.15 )  — index 4 is the number
        #expect(tokens[4] == .number(0.15))
    }

    @Test func test_tokenize_negativeNumber() throws {
        let tokens = try Tokenizer(input: "filter(profit > -500)").tokenize()
        // tokens: filter ( profit > -500 )  — index 4 is the negative number
        #expect(tokens[4] == .intNumber(-500))
    }

    @Test func test_tokenize_comment() throws {
        let tokens = try Tokenizer(input: "# comment\nhead(5)").tokenize()
        #expect(tokens == [
            .identifier("head"), .openParen, .intNumber(5), .closeParen
        ])
    }

    // MARK: - DSL Parser: Single Operations

    @Test func test_parse_filter_greaterThan() throws {
        let ops = try DSLParser.parse("filter(revenue > 10000)")
        #expect(ops.count == 1)
        guard case .filter(let expr) = ops[0] else { Issue.record("Expected filter"); return }
        #expect(expr.column == "revenue")
        #expect(expr.op == .gt)
        #expect(expr.value == .integer(10000))
    }

    @Test func test_parse_filter_stringEquality() throws {
        let ops = try DSLParser.parse("filter(status == \"active\")")
        guard case .filter(let expr) = ops[0] else { Issue.record("Expected filter"); return }
        #expect(expr.op == .eq)
        #expect(expr.value == .string("active"))
    }

    @Test func test_parse_filter_contains() throws {
        let ops = try DSLParser.parse("filter(sku contains \"001\")")
        guard case .filter(let expr) = ops[0] else { Issue.record("Expected filter"); return }
        #expect(expr.op == .contains)
        #expect(expr.value == .string("001"))
    }

    @Test func test_parse_sort_desc() throws {
        let ops = try DSLParser.parse("sort(revenue, desc)")
        guard case .sort(let specs) = ops[0] else { Issue.record("Expected sort"); return }
        #expect(specs.count == 1)
        #expect(specs[0].column == "revenue")
        #expect(specs[0].direction == .desc)
    }

    @Test func test_parse_sort_multiColumn() throws {
        let ops = try DSLParser.parse("sort(region asc, revenue desc)")
        guard case .sort(let specs) = ops[0] else { Issue.record("Expected sort"); return }
        #expect(specs.count == 2)
        #expect(specs[0].direction == .asc)
        #expect(specs[1].direction == .desc)
    }

    @Test func test_parse_groupby() throws {
        let ops = try DSLParser.parse("groupby(region, quarter)")
        guard case .groupBy(let cols) = ops[0] else { Issue.record("Expected groupBy"); return }
        #expect(cols == ["region", "quarter"])
    }

    @Test func test_parse_agg() throws {
        let ops = try DSLParser.parse("agg(sum:revenue, mean:margin, count:transactions)")
        guard case .aggregate(let specs) = ops[0] else { Issue.record("Expected aggregate"); return }
        #expect(specs.count == 3)
        #expect(specs[0].fn == .sum)
        #expect(specs[0].col == "revenue")
        #expect(specs[1].fn == .mean)
        #expect(specs[2].fn == .count)
    }

    @Test func test_parse_select() throws {
        let ops = try DSLParser.parse("select(region, revenue)")
        guard case .select(let cols) = ops[0] else { Issue.record("Expected select"); return }
        #expect(cols == ["region", "revenue"])
    }

    @Test func test_parse_drop() throws {
        let ops = try DSLParser.parse("drop(cost, status)")
        guard case .drop(let cols) = ops[0] else { Issue.record("Expected drop"); return }
        #expect(cols == ["cost", "status"])
    }

    @Test func test_parse_rename() throws {
        let ops = try DSLParser.parse("rename(revenue -> total_revenue)")
        guard case .rename(let from, let to) = ops[0] else { Issue.record("Expected rename"); return }
        #expect(from == "revenue")
        #expect(to == "total_revenue")
    }

    @Test func test_parse_head() throws {
        let ops = try DSLParser.parse("head(5)")
        guard case .head(let n) = ops[0] else { Issue.record("Expected head"); return }
        #expect(n == 5)
    }

    @Test func test_parse_tail() throws {
        let ops = try DSLParser.parse("tail(3)")
        guard case .tail(let n) = ops[0] else { Issue.record("Expected tail"); return }
        #expect(n == 3)
    }

    @Test func test_parse_round() throws {
        let ops = try DSLParser.parse("round(margin, 2)")
        guard case .round(let col, let d) = ops[0] else { Issue.record("Expected round"); return }
        #expect(col == "margin")
        #expect(d == 2)
    }

    @Test func test_parse_derive() throws {
        let ops = try DSLParser.parse("derive(profit = revenue - cost)")
        guard case .derive(let name, let expr) = ops[0] else { Issue.record("Expected derive"); return }
        #expect(name == "profit")
        if case .binary(let lhs, let op, let rhs) = expr {
            #expect(lhs == .columnRef("revenue"))
            #expect(op == .sub)
            #expect(rhs == .columnRef("cost"))
        } else {
            Issue.record("Expected binary expression")
        }
    }

    @Test func test_parse_cast() throws {
        let ops = try DSLParser.parse("cast(transactions, Int)")
        guard case .cast(let col, let target) = ops[0] else { Issue.record("Expected cast"); return }
        #expect(col == "transactions")
        #expect(target == .int)
    }

    // MARK: - Chains

    @Test func test_parse_chainOfThree() throws {
        let ops = try DSLParser.parse("filter(revenue > 0) | sort(revenue, desc) | head(5)")
        #expect(ops.count == 3)
    }

    @Test func test_parse_multilineChain() throws {
        let raw = """
          filter(status == "active") |
          groupby(region)            |
          agg(sum:revenue)
        """
        let ops = try DSLParser.parse(raw)
        #expect(ops.count == 3)
    }

    // MARK: - Error Cases

    @Test func test_unknownOperation_throws() throws {
        #expect(throws: (any Error).self) {
            try DSLParser.parse("explode(col)")
        }
    }

    @Test func test_malformedParens_throws() throws {
        #expect(throws: (any Error).self) {
            try DSLParser.parse("filter(revenue > 10000")
        }
    }

    @Test func test_emptyInput_throws() throws {
        #expect(throws: (any Error).self) {
            try DSLParser.parse("")
        }
    }

    // MARK: - Arithmetic Expression Parser

    @Test func test_arithExpr_simple() throws {
        let tokens = try Tokenizer(input: "revenue - cost").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        #expect(expr == .binary(.columnRef("revenue"), .sub, .columnRef("cost")))
    }

    @Test func test_arithExpr_precedence() throws {
        // a + b * c should parse as a + (b * c)
        let tokens = try Tokenizer(input: "a + b * c").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        if case .binary(let lhs, .add, let rhs) = expr {
            #expect(lhs == .columnRef("a"))
            if case .binary(.columnRef("b"), .mul, .columnRef("c")) = rhs {
                // OK
            } else {
                Issue.record("Expected b * c on right side")
            }
        } else {
            Issue.record("Expected addition at top level")
        }
    }

    @Test func test_arithExpr_literal() throws {
        let tokens = try Tokenizer(input: "revenue * 100").tokenize()
        let expr = try DSLParser.parseArithExpr(tokens)
        #expect(expr == .binary(.columnRef("revenue"), .mul, .literal(100.0)))
    }

    // MARK: - JSON Transform Parser

    @Test func test_jsonParser_filter() throws {
        let json = """
        {
          "operations": [
            { "op": "filter", "args": { "column": "revenue", "operator": ">", "value": 10000 } }
          ]
        }
        """
        let ops = try JSONTransformParser.parse(from: json)
        #expect(ops.count == 1)
        guard case .filter(let expr) = ops[0] else { Issue.record("Expected filter"); return }
        #expect(expr.column == "revenue")
        #expect(expr.op == .gt)
    }

    @Test func test_jsonParser_fullPipeline() throws {
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
        #expect(ops.count == 4)
    }

    @Test func test_jsonParser_invalidJSON_throws() throws {
        #expect(throws: (any Error).self) {
            try JSONTransformParser.parse(from: "not json")
        }
    }

    @Test func test_jsonParser_missingOperations_throws() throws {
        #expect(throws: (any Error).self) {
            try JSONTransformParser.parse(from: "{}")
        }
    }

    @Test func test_jsonParser_unknownOp_throws() throws {
        let json = """
        { "operations": [{ "op": "explode", "args": {} }] }
        """
        #expect(throws: (any Error).self) {
            try JSONTransformParser.parse(from: json)
        }
    }

    @Test func test_jsonParser_missingArgs_throws() throws {
        let json = """
        { "operations": [{ "op": "filter" }] }
        """
        #expect(throws: (any Error).self) {
            try JSONTransformParser.parse(from: json)
        }
    }
}
