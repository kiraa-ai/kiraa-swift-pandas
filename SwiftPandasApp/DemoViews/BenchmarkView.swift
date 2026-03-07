import SwiftUI
import SwiftPandas

struct BenchmarkView: View {
    @State private var output = "Configure dataset size and press 'Run Benchmark'..."
    @State private var rowCount = 100_000
    @State private var isRunning = false

    private let rowOptions = [10_000, 100_000, 500_000, 1_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metal GPU Benchmark")
                .font(.title2.bold())

            HStack {
                Text("Rows:")
                Picker("Rows", selection: $rowCount) {
                    ForEach(rowOptions, id: \.self) { n in
                        Text(formatNumber(n)).tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)

                Button("Run Benchmark") { runBenchmark() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning)

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Metal GPU active for >= \(formatNumber(MetalDispatch.groupByThreshold)) rows")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding()
    }

    private func runBenchmark() {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = performBenchmark()
            DispatchQueue.main.async {
                output = result
                isRunning = false
            }
        }
    }

    private func performBenchmark() -> String {
        var lines = [String]()
        let n = rowCount
        let nGroups = 100

        lines.append("Dataset: \(formatNumber(n)) rows, \(nGroups) groups")
        lines.append("Metal available: \(MetalDispatch.isAvailable)")
        lines.append("GPU threshold: \(formatNumber(MetalDispatch.groupByThreshold)) rows")
        lines.append("GPU active: \(MetalDispatch.shouldUseGPU(rowCount: n, threshold: MetalDispatch.groupByThreshold))")
        lines.append("")

        // Build test DataFrame
        var groups = [String]()
        groups.reserveCapacity(n)
        var values = [Double]()
        values.reserveCapacity(n)
        var seed: UInt64 = 42
        for _ in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let g = Int(seed >> 33) % nGroups
            groups.append("g\(g)")
            let bits = seed >> 11
            values.append(Double(bits) / Double(1 << 53) * 1000.0)
        }

        let df = DataFrame(columns: [
            ("group", Column.fromStrings(groups)),
            ("value", Column.fromDoubles(values)),
        ])

        let gb = df.groupBy("group")

        // Benchmark each operation (best of 3)
        func bench(_ label: String, _ block: () -> Void) -> String {
            var best = Double.infinity
            for _ in 0..<3 {
                let start = CFAbsoluteTimeGetCurrent()
                block()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
                if elapsed < best { best = elapsed }
            }
            return String(format: "  %-12s %12.1f \u{00B5}s", label, best)
        }

        lines.append("Operation      Time (\u{00B5}s)")
        lines.append(String(repeating: "-", count: 30))
        lines.append(bench("sum()") { _ = gb.sum() })
        lines.append(bench("mean()") { _ = gb.mean() })
        lines.append(bench("count()") { _ = gb.count() })
        lines.append(bench("min()") { _ = gb.min() })
        lines.append(bench("max()") { _ = gb.max() })

        // Also benchmark filter
        lines.append("")
        lines.append("Filter:")
        lines.append(String(repeating: "-", count: 30))
        let filterMask = [Bool](repeating: false, count: n).enumerated().map { i, _ in i % 2 == 0 }
        lines.append(bench("filter 50%") { _ = df.filter(mask: filterMask) })

        return lines.joined(separator: "\n")
    }

    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
