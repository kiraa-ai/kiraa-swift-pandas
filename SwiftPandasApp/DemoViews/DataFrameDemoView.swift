import SwiftUI
import SwiftPandas

struct DataFrameDemoView: View {
    @State private var output = "Press 'Run Demo' to start..."

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

    private func runDemo() {
        var lines = [String]()

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

        // Aggregation
        let salaries = df["salary"]
        lines.append("\n=== Salary Statistics ===")
        lines.append("Sum:    \(salaries.sum())")
        lines.append("Mean:   \(salaries.mean())")
        lines.append("Min:    \(salaries.min())")
        lines.append("Max:    \(salaries.max())")
        lines.append("Median: \(salaries.median())")

        // Describe
        lines.append("\n=== describe() ===")
        lines.append(df.describe().description)

        // CSV round-trip
        let csv = df.toCSV()
        lines.append("\n=== CSV Output ===")
        lines.append(csv)

        output = lines.joined(separator: "\n")
    }
}
