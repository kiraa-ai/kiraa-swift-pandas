import ArgumentParser
import Foundation
import SwiftPandas

@main
struct SwiftPandasCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftpandas",
        abstract: "Fast CSV transformation tool using a pipe-chained DSL.",
        discussion: """
        Transform CSV data using inline DSL chains (-c) or JSON transform files (-f).

        Inline DSL example:
          swiftpandas -i data.csv -o out.csv -c "filter(revenue > 10000) | sort(revenue, desc)"

        JSON file example:
          swiftpandas -i data.csv -o out.csv -f transforms.json

        Use --help-ops to see all available operations and their JSON schemas.
        """
    )

    @Option(name: .shortAndLong, help: "Input CSV file path (required for CLI mode)")
    var input: String?

    @Option(name: .shortAndLong, help: "Output CSV file path (stdout if omitted)")
    var output: String?

    @Option(name: .shortAndLong, help: "Inline DSL transform chain")
    var chain: String?

    @Option(name: .shortAndLong, help: "Path to a .json transform file")
    var file: String?

    @Option(name: .long, help: "Column delimiter (default: comma)")
    var sep: String = ","

    @Flag(name: .long, help: "Print schema and row count, do not write output")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print row count after each transform stage")
    var verbose: Bool = false

    @Flag(name: .long, help: "Show all operation schemas and examples")
    var helpOps: Bool = false

    @Flag(name: .shortAndLong, help: "Suppress CSV output (useful with --verbose to see only stats)")
    var quiet: Bool = false

    #if canImport(SwiftUI) && canImport(AppKit)
    @Flag(name: .long, help: "Launch interactive GUI mode")
    var gui: Bool = false
    #endif

    func run() throws {
        #if canImport(SwiftUI) && canImport(AppKit)
        if gui {
            launchGUI()
            return
        }
        #endif

        let totalStart = CFAbsoluteTimeGetCurrent()

        // --help-ops: print operation reference and exit
        if helpOps {
            printOperationHelp()
            return
        }

        // Require input file in CLI mode
        guard let input = input else {
            throw CleanExit.message("Error: -i/--input is required in CLI mode. Use --gui for interactive mode.")
        }

        if verbose {
            logStderr("")
            logStderr("  \(Style.bold)swiftpandas\(Style.reset) \(Style.dim)— CSV transformation pipeline\(Style.reset)")
            logStderr("  \(Style.dim)\(String(repeating: "─", count: 56))\(Style.reset)")
        }

        // ── Step 1: Validate arguments ──
        if verbose {
            logStderr("  \(Style.cyan)✓ args\(Style.reset)    \(Style.dim)│\(Style.reset) input: \(input)")
            if let c = chain {
                let preview = c.count > 40 ? String(c.prefix(40)) + "…" : c
                logStderr("            \(Style.dim)│\(Style.reset) chain: \(preview)")
            }
            if let f = file {
                logStderr("            \(Style.dim)│\(Style.reset) file:  \(f)")
            }
            if let o = output {
                logStderr("            \(Style.dim)│\(Style.reset) output: \(o)")
            }
            logStderr("            \(Style.dim)│\(Style.reset) sep: \"\(sep)\"  dry-run: \(dryRun)  quiet: \(quiet)")
        }

        guard chain != nil || file != nil else {
            if verbose { logFail("No transform provided (need -c or -f)") }
            throw CLIError.noTransformProvided
        }

        // ── Step 2: Validate input file ──
        guard FileManager.default.fileExists(atPath: input) else {
            if verbose { logFail("Input file not found: \(input)") }
            throw CLIError.fileNotFound(input)
        }

        let separator = sep.first ?? ","
        let readStart = CFAbsoluteTimeGetCurrent()
        let df: DataFrame
        do {
            df = try DataFrame.readCSV(path: input, separator: separator)
        } catch {
            if verbose { logFail("Failed to read CSV: \(error.localizedDescription)") }
            throw error
        }
        let readTime = CFAbsoluteTimeGetCurrent() - readStart

        if verbose {
            logStderr("  \(Style.cyan)✓ read\(Style.reset)    \(Style.dim)│\(Style.reset) \(URL(fileURLWithPath: input).lastPathComponent)")
            logStderr("            \(Style.dim)│\(Style.reset) \(formatCount(df.rowCount)) rows × \(formatCount(df.columnCount)) cols  \(Style.dim)\(formatTime(readTime))\(Style.reset)")
        }

        // ── Step 3: Parse transform operations ──
        let parseStart = CFAbsoluteTimeGetCurrent()
        let operations: [Operation]
        do {
            if let chain = chain {
                operations = try DSLParser.parse(chain)
            } else if let filePath = file {
                guard FileManager.default.fileExists(atPath: filePath) else {
                    if verbose { logFail("Transform file not found: \(filePath)") }
                    throw CLIError.fileNotFound(filePath)
                }
                let contents = try String(contentsOfFile: filePath, encoding: .utf8)
                if filePath.hasSuffix(".json") {
                    operations = try JSONTransformParser.parse(from: contents)
                } else {
                    operations = try DSLParser.parse(contents)
                }
            } else {
                throw CLIError.noTransformProvided
            }
        } catch {
            if verbose { logFail("Parse error: \(error.localizedDescription)") }
            throw error
        }
        let parseTime = CFAbsoluteTimeGetCurrent() - parseStart

        if verbose {
            let source = chain != nil ? "inline DSL" : (file?.hasSuffix(".json") == true ? "JSON file" : "DSL file")
            logStderr("  \(Style.cyan)✓ parse\(Style.reset)   \(Style.dim)│\(Style.reset) \(operations.count) operation\(operations.count == 1 ? "" : "s") from \(source)  \(Style.dim)\(formatTime(parseTime))\(Style.reset)")
        }

        // ── Step 4: Validate column references ──
        if verbose {
            let allCols = Set(df.columnNames)
            let referencedCols = extractReferencedColumns(operations)
            let missing = referencedCols.subtracting(allCols)
            if missing.isEmpty {
                logStderr("  \(Style.cyan)✓ validate\(Style.reset) \(Style.dim)│\(Style.reset) all column references valid")
            } else {
                logStderr("  \(Style.yellow)⚠ validate\(Style.reset) \(Style.dim)│\(Style.reset) unknown columns: \(missing.sorted().joined(separator: ", "))")
            }
        }

        // Dry run mode
        if dryRun {
            if verbose {
                logStderr("  \(Style.dim)\(String(repeating: "─", count: 56))\(Style.reset)")
            }
            printDryRun(df: df, operations: operations, inputPath: input)
            return
        }

        // ── Step 5: Execute pipeline ──
        if verbose {
            logStderr("  \(Style.dim)\(String(repeating: "─", count: 56))\(Style.reset)")
            logStderr("  \(Style.bold)Pipeline\(Style.reset)  \(Style.dim)│\(Style.reset) executing \(operations.count) stage\(operations.count == 1 ? "" : "s")…")
        }

        let pipelineStart = CFAbsoluteTimeGetCurrent()
        let result: DataFrame
        do {
            let runner = TransformRunner(operations: operations, verbose: verbose)
            result = try runner.run(on: df)
        } catch {
            if verbose { logFail("Pipeline error: \(error.localizedDescription)") }
            throw error
        }
        let pipelineTime = CFAbsoluteTimeGetCurrent() - pipelineStart

        // ── Step 6: Write output ──
        if verbose {
            logStderr("  \(Style.dim)\(String(repeating: "─", count: 56))\(Style.reset)")
        }

        let writeStart = CFAbsoluteTimeGetCurrent()
        if let outputPath = output {
            do {
                try result.toCSV(path: outputPath, separator: sep)
            } catch {
                if verbose { logFail("Write error: \(error.localizedDescription)") }
                throw error
            }
        } else if !quiet {
            let csv = result.toCSV(separator: sep)
            print(csv, terminator: "")
        }
        let writeTime = CFAbsoluteTimeGetCurrent() - writeStart
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart

        if verbose {
            if let outputPath = output {
                logStderr("  \(Style.green)✓ write\(Style.reset)   \(Style.dim)│\(Style.reset) \(outputPath)")
                logStderr("            \(Style.dim)│\(Style.reset) \(formatCount(result.rowCount)) rows × \(formatCount(result.columnCount)) cols  \(Style.dim)\(formatTime(writeTime))\(Style.reset)")
            } else if quiet {
                logStderr("  \(Style.yellow)– output\(Style.reset)  \(Style.dim)│\(Style.reset) suppressed (--quiet)")
            } else {
                logStderr("  \(Style.green)✓ stdout\(Style.reset)  \(Style.dim)│\(Style.reset) \(formatCount(result.rowCount)) rows × \(formatCount(result.columnCount)) cols  \(Style.dim)\(formatTime(writeTime))\(Style.reset)")
            }

            // ── Summary ──
            logStderr("  \(Style.dim)\(String(repeating: "═", count: 56))\(Style.reset)")
            logStderr("  \(Style.green)\(Style.bold)✓ Success\(Style.reset) \(Style.dim)│\(Style.reset) \(formatCount(df.rowCount)) → \(formatCount(result.rowCount)) rows  \(Style.dim)│\(Style.reset)  read \(formatTime(readTime))  pipeline \(formatTime(pipelineTime))  write \(formatTime(writeTime))")
            logStderr("            \(Style.dim)│\(Style.reset) total \(Style.bold)\(formatTime(totalTime))\(Style.reset)")
            logStderr("")
        }
    }

    // MARK: - Column Reference Extraction (for validation)

    private func extractReferencedColumns(_ operations: [Operation]) -> Set<String> {
        var cols = Set<String>()
        for op in operations {
            switch op {
            case .filter(let expr): cols.insert(expr.column)
            case .sort(let specs): specs.forEach { cols.insert($0.column) }
            case .select(let c), .drop(let c), .groupBy(let c): c.forEach { cols.insert($0) }
            case .rename(let from, _): cols.insert(from)
            case .round(let col, _): cols.insert(col)
            case .cast(let col, _): cols.insert(col)
            case .aggregate(let specs): specs.forEach { cols.insert($0.col) }
            case .derive(_, let expr): extractArithColumns(expr, into: &cols)
            case .head, .tail: break
            }
        }
        return cols
    }

    private func extractArithColumns(_ expr: ArithExpr, into cols: inout Set<String>) {
        switch expr {
        case .columnRef(let c): cols.insert(c)
        case .literal, .stringLiteral: break
        case .binary(let l, _, let r):
            extractArithColumns(l, into: &cols)
            extractArithColumns(r, into: &cols)
        }
    }

    private func logFail(_ message: String) {
        logStderr("  \(Style.dim)\(String(repeating: "─", count: 56))\(Style.reset)")
        logStderr("  \(Style.red)\(Style.bold)✗ Failed\(Style.reset) \(Style.dim)│\(Style.reset) \(message)")
        logStderr("")
    }

    // MARK: - Dry Run

    private func printDryRun(df: DataFrame, operations: [Operation], inputPath: String) {
        print("")
        print("  \(Style.bold)swiftpandas\(Style.reset) \(Style.dim)— dry run\(Style.reset)")
        print("  \(Style.dim)\(String(repeating: "─", count: 50))\(Style.reset)")

        print("  \(Style.cyan)Schema\(Style.reset) \(Style.dim)│\(Style.reset) \(inputPath)")
        print("         \(Style.dim)│\(Style.reset) \(formatCount(df.rowCount)) rows × \(formatCount(df.columnCount)) cols")
        print("         \(Style.dim)│\(Style.reset)")

        let maxNameLen = df.columnNames.map { $0.count }.max() ?? 0
        for (name, dtype) in df.dtypes {
            let padded = name.padding(toLength: maxNameLen + 2, withPad: " ", startingAt: 0)
            let typeStr: String
            switch dtype {
            case .float64: typeStr = "Double"
            case .int64: typeStr = "Int"
            case .string: typeStr = "String"
            case .bool: typeStr = "Bool"
            default: typeStr = "\(dtype)"
            }
            print("         \(Style.dim)│\(Style.reset)   \(Style.bold)\(padded)\(Style.reset)\(Style.dim)\(typeStr)\(Style.reset)")
        }

        print("  \(Style.dim)\(String(repeating: "─", count: 50))\(Style.reset)")
        print("  \(Style.yellow)Pipeline\(Style.reset) \(Style.dim)│\(Style.reset) \(operations.count) stage\(operations.count == 1 ? "" : "s")")
        for (i, op) in operations.enumerated() {
            let num = String(format: "%2d", i + 1)
            print("           \(Style.dim)│\(Style.reset) \(Style.dim)\(num).\(Style.reset) \(describeOperation(op))")
        }

        print("  \(Style.dim)\(String(repeating: "─", count: 50))\(Style.reset)")
        print("  \(Style.dim)No output written (dry run)\(Style.reset)")
        print("")
    }

    // MARK: - Operation Help

    private func printOperationHelp() {
        let ops = ["filter", "sort", "groupby", "agg", "select", "drop",
                   "rename", "head", "tail", "round", "derive", "cast"]
        print("SwiftPandas CLI — Operation Reference")
        print("=====================================\n")
        print("Operations can be used via inline DSL (-c) or JSON files (-f).\n")

        print("--- Inline DSL Syntax ---\n")
        print("  swiftpandas -i data.csv -c \"filter(revenue > 10000) | sort(revenue, desc) | head(10)\"\n")

        print("--- JSON File Format ---\n")
        print("""
        {
          "description": "Pipeline description",
          "operations": [
            { "op": "filter", "args": { ... } },
            ...
          ]
        }
        """)
        print("")

        print("--- Operations ---\n")
        for op in ops {
            print(JSONTransformParser.operationHelpText(op))
            print("")
        }
    }

    // MARK: - Describe Operation

    private func describeOperation(_ op: Operation) -> String {
        switch op {
        case .filter(let expr):
            let valueStr: String
            switch expr.value {
            case .number(let v): valueStr = "\(v)"
            case .integer(let v): valueStr = "\(v)"
            case .string(let v): valueStr = "\"\(v)\""
            }
            return "filter(\(expr.column) \(expr.op.rawValue) \(valueStr))"
        case .sort(let specs):
            let parts = specs.map { "\($0.column) \($0.direction.rawValue)" }
            return "sort(\(parts.joined(separator: ", ")))"
        case .groupBy(let cols):
            return "groupby(\(cols.joined(separator: ", ")))"
        case .aggregate(let specs):
            let parts = specs.map { "\($0.fn.rawValue):\($0.col)" }
            return "agg(\(parts.joined(separator: ", ")))"
        case .select(let cols):
            return "select(\(cols.joined(separator: ", ")))"
        case .drop(let cols):
            return "drop(\(cols.joined(separator: ", ")))"
        case .rename(let from, let to):
            return "rename(\(from) -> \(to))"
        case .head(let n):
            return "head(\(n))"
        case .tail(let n):
            return "tail(\(n))"
        case .round(let col, let d):
            return "round(\(col), \(d))"
        case .derive(let name, _):
            return "derive(\(name) = ...)"
        case .cast(let col, let target):
            return "cast(\(col), \(target.rawValue))"
        }
    }

    private func logStderr(_ msg: String) {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
    }

    // MARK: - Formatting

    private func formatTime(_ seconds: Double) -> String {
        if seconds < 0.001 {
            return String(format: "%.0fµs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.1fms", seconds * 1_000)
        } else if seconds < 60.0 {
            return String(format: "%.2fs", seconds)
        } else {
            let mins = Int(seconds) / 60
            let secs = seconds - Double(mins * 60)
            return String(format: "%dm%.1fs", mins, secs)
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
}

// MARK: - ANSI Style

enum Style {
    static let isTerminal = isatty(STDERR_FILENO) != 0

    static var bold: String    { isTerminal ? "\u{1B}[1m" : "" }
    static var dim: String     { isTerminal ? "\u{1B}[2m" : "" }
    static var reset: String   { isTerminal ? "\u{1B}[0m" : "" }
    static var cyan: String    { isTerminal ? "\u{1B}[36m" : "" }
    static var green: String   { isTerminal ? "\u{1B}[32m" : "" }
    static var yellow: String  { isTerminal ? "\u{1B}[33m" : "" }
    static var red: String     { isTerminal ? "\u{1B}[31m" : "" }
    static var magenta: String { isTerminal ? "\u{1B}[35m" : "" }
}
