// MARK: - SwiftPandasApp.swift
// MARK: Application Entry Point
//
// This file defines the main entry point for the SwiftPandas demo application.
// The app launches a single window containing the `ContentView`, which provides
// a tab-based interface for exploring DataFrame operations, GroupBy aggregations,
// and Metal GPU benchmark performance.

import SwiftUI

/// The main application struct for the SwiftPandas demo app.
///
/// Uses SwiftUI's `@main` attribute to designate this as the application entry point.
/// The app presents a single `WindowGroup` scene containing the root `ContentView`,
/// with a default window size of 900x700 points suitable for displaying tabular data output.
@main
struct SwiftPandasApp: App {
    /// The root scene of the application, consisting of a single window group.
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 900, height: 700)
    }
}
