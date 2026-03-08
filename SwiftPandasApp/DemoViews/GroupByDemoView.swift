// MARK: - GroupByDemoView.swift
// MARK: GroupBy Split-Apply-Combine Demo
//
// This file provides an interactive SwiftUI view demonstrating the GroupBy
// (split-apply-combine) operations available in the SwiftPandas library.
// When the user taps "Run GroupBy", it constructs a sample DataFrame with
// department, salary, and bonus columns, then groups by department and
// applies the following aggregation functions:
//   - sum: total of each numeric column per group
//   - mean: average of each numeric column per group
//   - count: number of rows per group
//   - min: minimum value per group
//   - max: maximum value per group

import SwiftUI
import SwiftPandas

/// A view that demonstrates GroupBy aggregation operations on a sample
/// employee dataset grouped by department.
///
/// The view displays a "Run GroupBy" button and a scrollable output area.
/// Tapping the button constructs a 10-row DataFrame across three departments
/// (Engineering, Sales, Marketing) and runs all five aggregation functions.
struct GroupByDemoView: View {
    /// The accumulated output text from the most recent GroupBy demo run.
    @State private var output = "Press 'Run GroupBy' to start..."

    /// The view layout: a title, action button, and scrollable output area.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GroupBy Demo")
                .font(.title2.bold())

            Button("Run GroupBy") { runDemo() }
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

    /// Executes the GroupBy demo and updates the `output` state.
    ///
    /// Builds a sample DataFrame with 10 employees across Engineering, Sales,
    /// and Marketing departments, each with salary and bonus columns.
    /// Groups by department and runs sum, mean, count, min, and max aggregations.
    private func runDemo() {
        var lines = [String]()

        // Construct a sample DataFrame with three departments and two numeric columns
        let df = DataFrame(columns: [
            ("department", Column.fromStrings([
                "Engineering", "Sales", "Engineering", "Marketing",
                "Sales", "Engineering", "Marketing", "Sales",
                "Engineering", "Marketing"
            ])),
            ("salary", Column.fromDoubles([
                95000, 72000, 88000, 65000,
                76000, 102000, 58000, 81000,
                91000, 70000
            ])),
            ("bonus", Column.fromDoubles([
                15000, 8000, 12000, 5000,
                9000, 18000, 4000, 10000,
                14000, 6000
            ])),
        ])

        lines.append("=== Source DataFrame ===")
        lines.append(df.description)

        // Group by department for split-apply-combine aggregation
        let gb = df.groupBy("department")

        // Apply each aggregation function and display the results
        lines.append("\n=== GroupBy Sum ===")
        lines.append(gb.sum().description)

        lines.append("\n=== GroupBy Mean ===")
        lines.append(gb.mean().description)

        lines.append("\n=== GroupBy Count ===")
        lines.append(gb.count().description)

        lines.append("\n=== GroupBy Min ===")
        lines.append(gb.min().description)

        lines.append("\n=== GroupBy Max ===")
        lines.append(gb.max().description)

        output = lines.joined(separator: "\n")
    }
}
