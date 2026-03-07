import SwiftUI
import SwiftPandas

struct GroupByDemoView: View {
    @State private var output = "Press 'Run GroupBy' to start..."

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

    private func runDemo() {
        var lines = [String]()

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

        let gb = df.groupBy("department")

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
