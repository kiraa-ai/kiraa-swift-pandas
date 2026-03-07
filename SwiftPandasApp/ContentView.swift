import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DataFrameDemoView()
                .tabItem { Label("DataFrame", systemImage: "tablecells") }
            GroupByDemoView()
                .tabItem { Label("GroupBy", systemImage: "chart.bar") }
            BenchmarkView()
                .tabItem { Label("Benchmark", systemImage: "speedometer") }
        }
        .padding()
    }
}
