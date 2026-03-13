import Foundation

// MARK: - Token

enum Token: Equatable {
    case identifier(String)
    case number(Double)
    case intNumber(Int)
    case stringLiteral(String)
    case op(ComparisonOp)
    case arithmeticOp(ArithOp)
    case comma
    case openParen
    case closeParen
    case colon
    case arrow          // ->
    case equals         // = (assignment in derive)
    case pipe           // |
}

enum ComparisonOp: String, Equatable {
    case gt = ">"
    case ge = ">="
    case lt = "<"
    case le = "<="
    case eq = "=="
    case ne = "!="
}

enum ArithOp: String, Equatable {
    case add = "+"
    case sub = "-"
    case mul = "*"
    case div = "/"
}

// MARK: - Tokenizer

struct Tokenizer {
    let input: String

    func tokenize() throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            // Skip whitespace and newlines
            if c.isWhitespace || c.isNewline {
                i += 1
                continue
            }

            // Skip comments (# to end of line)
            if c == "#" {
                while i < chars.count && chars[i] != "\n" {
                    i += 1
                }
                continue
            }

            // String literal
            if c == "\"" {
                i += 1
                var str = ""
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        i += 1
                        str.append(chars[i])
                    } else {
                        str.append(chars[i])
                    }
                    i += 1
                }
                if i >= chars.count {
                    throw CLIError.malformedExpression("Unterminated string literal")
                }
                i += 1 // skip closing quote
                tokens.append(.stringLiteral(str))
                continue
            }

            // Arrow ->
            if c == "-" && i + 1 < chars.count && chars[i + 1] == ">" {
                tokens.append(.arrow)
                i += 2
                continue
            }

            // Two-char operators: >=, <=, ==, !=
            if i + 1 < chars.count {
                let two = String([chars[i], chars[i + 1]])
                if let op = ComparisonOp(rawValue: two) {
                    tokens.append(.op(op))
                    i += 2
                    continue
                }
            }

            // Single-char comparison operators: >, <
            if c == ">" {
                tokens.append(.op(.gt))
                i += 1
                continue
            }
            if c == "<" {
                tokens.append(.op(.lt))
                i += 1
                continue
            }

            // Pipe
            if c == "|" {
                tokens.append(.pipe)
                i += 1
                continue
            }

            // Single-char tokens
            if c == "(" { tokens.append(.openParen); i += 1; continue }
            if c == ")" { tokens.append(.closeParen); i += 1; continue }
            if c == "," { tokens.append(.comma); i += 1; continue }
            if c == ":" { tokens.append(.colon); i += 1; continue }

            // Assignment =
            if c == "=" {
                tokens.append(.equals)
                i += 1
                continue
            }

            // Arithmetic operators (but not negative numbers handled below)
            if c == "+" { tokens.append(.arithmeticOp(.add)); i += 1; continue }
            if c == "*" { tokens.append(.arithmeticOp(.mul)); i += 1; continue }
            if c == "/" { tokens.append(.arithmeticOp(.div)); i += 1; continue }

            // Numbers (including negative)
            if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                // Check if this minus is truly a negative sign vs subtraction
                let isNegative = c == "-"
                if isNegative {
                    // It's a negative number only if the previous token is an operator,
                    // open paren, comma, equals, pipe, or there's no previous token
                    let isUnary = tokens.isEmpty || {
                        switch tokens.last! {
                        case .op, .arithmeticOp, .openParen, .comma, .equals, .pipe, .colon:
                            return true
                        default:
                            return false
                        }
                    }()
                    if !isUnary {
                        tokens.append(.arithmeticOp(.sub))
                        i += 1
                        continue
                    }
                }

                var numStr = ""
                if isNegative { numStr.append("-"); i += 1 }
                var hasDot = false
                while i < chars.count && (chars[i].isNumber || (chars[i] == "." && !hasDot)) {
                    if chars[i] == "." { hasDot = true }
                    numStr.append(chars[i])
                    i += 1
                }
                if hasDot {
                    if let val = Double(numStr) {
                        tokens.append(.number(val))
                    } else {
                        throw CLIError.malformedExpression("Invalid number: \(numStr)")
                    }
                } else {
                    if let val = Int(numStr) {
                        tokens.append(.intNumber(val))
                    } else {
                        throw CLIError.malformedExpression("Invalid number: \(numStr)")
                    }
                }
                continue
            }

            // Minus as subtraction (not negative number)
            if c == "-" {
                tokens.append(.arithmeticOp(.sub))
                i += 1
                continue
            }

            // Identifiers (column names, keywords, operation names)
            if c.isLetter || c == "_" {
                var ident = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    ident.append(chars[i])
                    i += 1
                }
                tokens.append(.identifier(ident))
                continue
            }

            throw CLIError.malformedExpression("Unexpected character: '\(c)'")
        }

        return tokens
    }
}
