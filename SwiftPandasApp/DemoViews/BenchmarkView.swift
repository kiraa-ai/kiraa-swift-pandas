// MARK: - BenchmarkView.swift
// MARK: Metal GPU Benchmark Runner UI
//
// This file provides an interactive SwiftUI view for benchmarking SwiftPandas
// GroupBy and filter operations. The user can select a dataset size (10K to 1M rows)
// and run benchmarks that measure execution time in microseconds.
//
// The benchmark generates a synthetic DataFrame with a configurable number of rows
// and 100 groups, then times each GroupBy aggregation (sum, mean, count, min, max)
// and a 50% filter operation. Each operation is run 3 times and the best time is
// reported. When the row count exceeds the Metal GPU threshold, operations are
// automatically dispatched to the GPU for hardware-accelerated computation.
//
// The benchmark runs on a background thread to keep the UI responsive, with a
// progress indicator shown while running.

import SwiftUI
import SwiftPandas

/// A view that benchmarks SwiftPandas GroupBy and filter operations,
/// optionally leveraging Metal GPU acceleration for large datasets.
///
/// Provides a segmented picker for row count selection (10K, 100K, 500K, 1M),
/// a "Run Benchmark" button, and a scrollable output area displaying timing
/// results in microseconds. The view indicates whether Metal GPU acceleration
/// is active for the selected dataset size.
struct BenchmarkView: View {
    /// The accumulated benchmark output text.
    @State private var output = "Configure dataset size and press 'Run Benchmark'..."

    /// The number of rows in the synthetic benchmark dataset.
    @State private var rowCount = 100_000

    /// Whether a benchmark is currently executing on a background thread.
    @State private var isRunning = false

    /// The available row count options presented in the segmented picker.
    private let rowOptions = [10_000, 100_000, 500_000, 1_000_000]

    /// The view layout: title, row picker, run button, GPU status caption, and output area.
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

            // Display the threshold at which Metal GPU dispatch activates
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

    /// Launches the benchmark on a background thread and updates the UI when complete.
    ///
    /// Sets `isRunning` to true to disable the button and show a progress indicator,
    /// then dispatches the benchmark work to a `.userInitiated` quality-of-service queue.
    /// When complete, the results are posted back to the main thread.
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

    /// Generates a synthetic dataset and benchmarks GroupBy and filter operations.
    ///
    /// Creates a DataFrame with `rowCount` rows and 100 groups using a deterministic
    /// LCG (linear congruential generator) pseudo-random number generator seeded at 42.
    /// Each GroupBy aggregation (sum, mean, count, min, max) and a 50% filter are
    /// timed using `CFAbsoluteTimeGetCurrent`, running each operation 3 times and
    /// reporting the best (minimum) elapsed time in microseconds.
    ///
    /// - Returns: A formatted string containing benchmark configuration and timing results.
    private func performBenchmark() -> String {
        var lines = [String]()
        let n = rowCount
        let nGroups = 100

        // Report benchmark configuration and Metal GPU status
        lines.append("Dataset: \(formatNumber(n)) rows, \(nGroups) groups")
        lines.append("Metal available: \(MetalDispatch.isAvailable)")
        lines.append("GPU threshold: \(formatNumber(MetalDispatch.groupByThreshold)) rows")
        lines.append("GPU active: \(MetalDispatch.shouldUseGPU(rowCount: n, threshold: MetalDispatch.groupByThreshold))")
        lines.append("")

        // Build test DataFrame using a deterministic LCG PRNG for reproducibility
        var groups = [String]()
        groups.reserveCapacity(n)
        var values = [Double]()
        values.reserveCapacity(n)
        var seed: UInt64 = 42
        for _ in 0..<n {
            // LCG step: seed = seed * 6364136223846793005 + 1442695040888963407 (mod 2^64)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let g = Int(seed >> 33) % nGroups
            groups.append("g\(g)")
            // Convert upper bits to a Double in [0, 1000)
            let bits = seed >> 11
            values.append(Double(bits) / Double(1 << 53) * 1000.0)
        }

        let df = DataFrame(columns: [
            ("group", Column.fromStrings(groups)),
            ("value", Column.fromDoubles(values)),
        ])

        let gb = df.groupBy("group")

        // Benchmark helper: runs the given block 3 times and reports the best (minimum) time
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

        // Benchmark GroupBy aggregation operations
        lines.append("Operation      Time (\u{00B5}s)")
        lines.append(String(repeating: "-", count: 30))
        lines.append(bench("sum()") { _ = gb.sum() })
        lines.append(bench("mean()") { _ = gb.mean() })
        lines.append(bench("count()") { _ = gb.count() })
        lines.append(bench("min()") { _ = gb.min() })
        lines.append(bench("max()") { _ = gb.max() })

        // Benchmark filter operation with a 50% selectivity mask
        lines.append("")
        lines.append("Filter:")
        lines.append(String(repeating: "-", count: 30))
        let filterMask = [Bool](repeating: false, count: n).enumerated().map { i, _ in i % 2 == 0 }
        lines.append(bench("filter 50%") { _ = df.filter(mask: filterMask) })

        return lines.joined(separator: "\n")
    }

    /// Formats an integer with locale-appropriate thousands separators.
    ///
    /// - Parameter n: The integer to format.
    /// - Returns: A formatted string (e.g., "100,000") or the raw integer string as fallback.
    private func formatNumber(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
