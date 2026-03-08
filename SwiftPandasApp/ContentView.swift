// MARK: - ContentView.swift
// MARK: Root Tab-Based Navigation View
//
// This file defines the root content view of the SwiftPandas demo application.
// It provides a `TabView` with three tabs:
//   - DataFrame Demo: Interactive demonstration of DataFrame creation, filtering,
//     sorting, aggregation, and CSV round-trip operations.
//   - GroupBy Demo: Demonstration of split-apply-combine GroupBy operations
//     including sum, mean, count, min, and max aggregations.
//   - Benchmark: A configurable Metal GPU benchmark runner that measures
//     GroupBy and filter performance across different dataset sizes.

import SwiftUI

/// The root view of the SwiftPandas demo application.
///
/// Presents a tab-based interface that organizes the demo functionality into
/// three distinct sections. Each tab hosts a dedicated view for a specific
/// category of SwiftPandas operations.
struct ContentView: View {
    /// The main view body, composed of a padded `TabView` with three tabs.
    var body: some View {
        TabView {
            // Tab 1: DataFrame creation, manipulation, and CSV I/O
            DataFrameDemoView()
                .tabItem { Label("DataFrame", systemImage: "tablecells") }
            // Tab 2: GroupBy split-apply-combine operations
            GroupByDemoView()
                .tabItem { Label("GroupBy", systemImage: "chart.bar") }
            // Tab 3: Metal GPU benchmark runner
            BenchmarkView()
                .tabItem { Label("Benchmark", systemImage: "speedometer") }
        }
        .padding()
    }
}
