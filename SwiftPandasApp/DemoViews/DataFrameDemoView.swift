// MARK: - DataFrameDemoView.swift
// MARK: DataFrame Creation and Manipulation Demo
//
// This file provides an interactive SwiftUI view that demonstrates core
// DataFrame operations from the SwiftPandas library. When the user taps
// "Run Demo", it executes a sequence of operations and displays the
// results in a scrollable monospaced text view. Demonstrated operations:
//   - DataFrame construction from typed columns (strings, doubles)
//   - Boolean filtering using equality masks (e.g., department == "Engineering")
//   - Sorting by a numeric column in descending order
//   - Aggregation statistics: sum, mean, min, max, median
//   - The `describe()` summary statistics method
//   - CSV serialization round-trip via `toCSV()`

import SwiftUI
import SwiftPandas

/// A view that demonstrates DataFrame creation, filtering, sorting,
/// aggregation, and CSV output using the SwiftPandas library.
///
/// The view displays a "Run Demo" button and a scrollable output area.
/// Tapping the button executes all demo operations synchronously and
/// renders the results as monospaced text for easy inspection.
struct DataFrameDemoView: View {
    /// The accumulated output text from the most recent demo run.
    @State private var output = "Press 'Run Demo' to start..."

    /// The view layout: a title, action button, and scrollable output area.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DataFrame Demo")
                .font(.title2.bold())

            Button("Run Demo") { runDemo() }
                .buttonStyle(.borderedProminent)

            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    /// Executes the full DataFrame demo and updates the `output` state.
    ///
    /// Constructs a sample employee DataFrame with name, department, salary,
    /// and years columns, then runs filtering, sorting, aggregation,
    /// describe, and CSV export operations, collecting all output into
    /// a single string for display.
    private func runDemo() {
        var lines = [String]()

        // Construct a sample employee DataFrame with mixed column types
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("department", Column.fromStrings(["Engineering", "Sales", "Engineering", "Sales", "Engineering"])),
            ("salary", Column.fromDoubles([95000, 72000, 88000, 76000, 102000])),
            ("years", Column.fromDoubles([5, 3, 7, 4, 10])),
        ])

        lines.append("=== Constructed DataFrame ===")
        lines.append(df.description)

        // Filter: Engineering only
        let engMask = df["department"].eq("Engineering")
        let engineers = df.filter(mask: engMask)
        lines.append("\n=== Filtered: Engineering ===")
        lines.append(engineers.description)

        // Sort by salary descending
        let sorted = df.sortValues(by: "salary", ascending: false)
        lines.append("\n=== Sorted by Salary (desc) ===")
        lines.append(sorted.description)

        // Aggregation: compute summary statistics on the salary column
        let salaries = df["salary"]
        lines.append("\n=== Salary Statistics ===")
        lines.append("Sum:    \(salaries.sum())")
        lines.append("Mean:   \(salaries.mean())")
        lines.append("Min:    \(salaries.min())")
        lines.append("Max:    \(salaries.max())")
        lines.append("Median: \(salaries.median())")

        // Describe: full summary statistics for all numeric columns
        lines.append("\n=== describe() ===")
        lines.append(df.describe().description)

        // CSV round-trip: serialize to CSV string
        let csv = df.toCSV()
        lines.append("\n=== CSV Output ===")
        lines.append(csv)

        output = lines.joined(separator: "\n")
    }
}
