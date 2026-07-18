#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import SwiftPandas

// MARK: - GUI Launcher

/// Launches the SwiftUI GUI window using NSApplication.
/// Called from the CLI when --gui is passed.
func launchGUI() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let delegate = GUIAppDelegate()
    app.delegate = delegate
    app.run()
}

// MARK: - App Delegate

class GUIAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = GUIMainView()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwiftPandas — Transform Builder"
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Main View

struct GUIMainView: View {
    @StateObject private var vm = PipelineViewModel()

    var body: some View {
        HSplitView {
            // Left panel: config + operations
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "tablecells")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    Text("SwiftPandas")
                        .font(.title2.bold())
                    Spacer()
                }
                .padding()

                Divider()

                // Resident-daemon instance picker (new). Lets the user
                // operate on a DataFrame the daemon already holds in
                // memory instead of (or in addition to) browsing a CSV.
                InstanceSelectionSection(vm: vm)

                Divider()

                // File selection
                FileSelectionSection(vm: vm)

                Divider()

                // Operations
                OperationListSection(vm: vm)

                Divider()

                // Actions
                ActionBar(vm: vm)
            }
            .frame(minWidth: 340, idealWidth: 380)

            // Right panel: results
            ResultPanel(vm: vm)
                .frame(minWidth: 400)
        }
    }
}

// MARK: - Resident-daemon Instance Selection

/// Dropdown that lists DataFrames currently resident in the swiftpandas
/// daemon. Default selection is "(none)" — picking a DataFrame from the
/// dropdown loads a CSV preview into the result panel via a wire `show`.
///
/// The picker is grouped by `kind` (typically "transaction" + "metadata",
/// but any free-form string the user passed at `load` time is honored).
struct InstanceSelectionSection: View {
    @ObservedObject var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Daemon instance", systemImage: "server.rack")
                .font(.headline)

            HStack {
                // SwiftUI Picker with grouped `Section`s — produces a native
                // segmented dropdown with "Transaction" / "Metadata" / …
                // headers on macOS.
                Picker("", selection: $vm.selectedInstance) {
                    Text("(none)").tag(String?.none)
                    ForEach(vm.groupedInstances) { group in
                        // Show the kind tag as a section header. Capitalised
                        // so "transaction" → "Transaction" reads as a label.
                        Section(header: Text(group.kind.capitalized)) {
                            ForEach(group.entries, id: \.name) { entry in
                                // Show the byte count next to each name so
                                // the dropdown is informative on its own.
                                Text("\(entry.name)  —  \(InstanceSelectionSection.formatBytes(entry.bytes))")
                                    .tag(String?.some(entry.name))
                            }
                        }
                    }
                }
                .pickerStyle(.menu)
                .disabled(vm.availableInstances.isEmpty)

                Button {
                    vm.refreshInstances()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-query the daemon for its current list of resident DataFrames.")
            }

            Text(vm.instanceStatus)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        // Whenever the selection changes, fetch the preview from the daemon.
        // `.onChange(of:)` fires only on actual transitions, so picking the
        // same DataFrame twice doesn't re-fire — that's fine because the
        // refresh button gives the user an explicit way to re-pull.
        .onChange(of: vm.selectedInstance) { newValue in
            if let name = newValue {
                vm.loadFromInstance(name)
            }
        }
        // Run an initial refresh when the view appears so the user sees the
        // daemon state without having to hit the button first.
        .onAppear {
            vm.refreshInstances()
        }
    }

    /// Small standalone byte-formatter so this view doesn't depend on the
    /// top-level `formatBytes` symbol (which lives in `Style.swift` and may
    /// not be visible in all build configurations).
    static func formatBytes(_ bytes: Int) -> String {
        switch bytes {
        case _ where bytes >= 1_073_741_824:
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        case _ where bytes >= 1_048_576:
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        case _ where bytes >= 1_024:
            return String(format: "%.1f KB", Double(bytes) / 1_024)
        default:
            return "\(bytes) B"
        }
    }
}

// MARK: - File Selection

struct FileSelectionSection: View {
    @ObservedObject var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input CSV", systemImage: "doc.text")
                .font(.headline)

            HStack {
                TextField("Select a CSV file…", text: $vm.inputPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.commaSeparatedText, .data]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        vm.inputPath = url.path
                        vm.loadPreview()
                    }
                }
            }

            if !vm.previewInfo.isEmpty {
                Text(vm.previewInfo)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Separator:")
                    .font(.subheadline)
                Picker("", selection: $vm.separator) {
                    Text("Comma (,)").tag(",")
                    Text("Tab (\\t)").tag("\t")
                    Text("Semicolon (;)").tag(";")
                    Text("Pipe (|)").tag("|")
                }
                .frame(width: 140)
            }
        }
        .padding()
    }
}

// MARK: - Operation List

struct OperationListSection: View {
    @ObservedObject var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pipeline", systemImage: "arrow.right.arrow.left")
                    .font(.headline)
                Spacer()
                Button(action: { vm.addOperation() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Add operation")
            }

            if vm.operations.isEmpty {
                VStack(spacing: 4) {
                    Text("No operations yet")
                        .foregroundColor(.secondary)
                    Text("Click + to add a transform step")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(vm.operations.enumerated()), id: \.offset) { index, op in
                            OperationRow(vm: vm, index: index, operation: op)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }

            // Quick DSL entry
            HStack {
                TextField("Or enter DSL: filter(x > 10) | sort(x, desc)", text: $vm.dslInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { vm.parseDSL() }
                Button("Parse") { vm.parseDSL() }
                    .font(.caption)
            }
        }
        .padding()
    }
}

// MARK: - Operation Row

struct OperationRow: View {
    @ObservedObject var vm: PipelineViewModel
    let index: Int
    let operation: GUIOperation

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 20)

            Picker("", selection: binding(for: \.opType)) {
                ForEach(GUIOpType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .frame(width: 80)

            TextField("arguments", text: binding(for: \.args))
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))

            Button(action: { vm.removeOperation(at: index) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index % 2 == 0 ? Color.clear : Color.gray.opacity(0.06))
        )
    }

    private func binding(for keyPath: WritableKeyPath<GUIOperation, String>) -> Binding<String> {
        Binding(
            get: { vm.operations[index][keyPath: keyPath] },
            set: { vm.operations[index][keyPath: keyPath] = $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<GUIOperation, GUIOpType>) -> Binding<GUIOpType> {
        Binding(
            get: { vm.operations[index][keyPath: keyPath] },
            set: { vm.operations[index][keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Action Bar

struct ActionBar: View {
    @ObservedObject var vm: PipelineViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { vm.runPipeline() }) {
                    Label(vm.isRunning ? "Running…" : "Run Pipeline", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(vm.inputPath.isEmpty || vm.isRunning || vm.totalSteps == 0)

                Button(action: { vm.exportCSV() }) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .controlSize(.large)
                .disabled(vm.resultCSV.isEmpty)
            }

            if vm.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding()
    }
}

// MARK: - Result Panel

struct ResultPanel: View {
    @ObservedObject var vm: PipelineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status bar
            HStack {
                if !vm.statusMessage.isEmpty {
                    Image(systemName: vm.hasError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(vm.hasError ? .red : .green)
                    Text(vm.statusMessage)
                        .font(.subheadline)
                }
                Spacer()
                if !vm.timingInfo.isEmpty {
                    Text(vm.timingInfo)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Tabs for result display
            TabView {
                // Table tab
                ScrollView([.horizontal, .vertical]) {
                    Text(vm.resultText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .tabItem { Label("Table", systemImage: "tablecells") }

                // CSV tab
                ScrollView {
                    Text(vm.resultCSV.isEmpty ? "Run a pipeline to see CSV output" : vm.resultCSV)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .tabItem { Label("CSV", systemImage: "doc.text") }

                // Log tab
                ScrollView {
                    Text(vm.logOutput.isEmpty ? "Run a pipeline to see the execution log" : vm.logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .tabItem { Label("Log", systemImage: "terminal") }
            }
        }
    }
}

// MARK: - Operation Types

enum GUIOpType: String, CaseIterable {
    case filter, sort, select, drop, rename, head, tail
    case groupby, agg, round, derive, cast
}

struct GUIOperation {
    var opType: GUIOpType = .filter
    var args: String = ""
}

// MARK: - View Model

class PipelineViewModel: ObservableObject {
    @Published var inputPath = ""
    @Published var separator = ","
    @Published var operations: [GUIOperation] = []
    @Published var dslInput = ""
    @Published var previewInfo = ""

    @Published var isRunning = false
    @Published var resultText = "Select a CSV file and build your pipeline to get started."
    @Published var resultCSV = ""
    @Published var logOutput = ""
    @Published var statusMessage = ""
    @Published var timingInfo = ""
    @Published var hasError = false

    // MARK: - Daemon instance dropdown
    //
    // Lets the user pick a resident DataFrame from a running daemon instead
    // of (or in addition to) browsing for a local CSV. The dropdown stays
    // empty when no daemon is reachable; otherwise it lists every bound
    // DataFrame, grouped by `kind` (transaction / metadata / …).

    /// Snapshot of resident DataFrames in the daemon, ordered the same way
    /// the daemon returns them (oldest first). Empty when no daemon is
    /// running or the last refresh failed.
    @Published var availableInstances: [DataFrameRegistry.Entry] = []

    /// Currently selected resident DataFrame name, or `nil` for the "(none)"
    /// default. Changing this triggers a daemon-side `show` to populate the
    /// result panel with a CSV preview of the selected DF.
    @Published var selectedInstance: String? = nil

    /// One-line status describing the daemon state — refreshed on
    /// `refreshInstances()`. Displayed under the dropdown so the user knows
    /// whether the list is empty because no daemon is running or because
    /// the daemon genuinely has nothing loaded.
    @Published var instanceStatus: String = "Press Refresh to query the daemon."

    var totalSteps: Int {
        if !dslInput.trimmingCharacters(in: .whitespaces).isEmpty {
            return 1 // DSL counts as at least one
        }
        return operations.count
    }

    func addOperation() {
        operations.append(GUIOperation())
    }

    func removeOperation(at index: Int) {
        guard operations.indices.contains(index) else { return }
        operations.remove(at: index)
    }

    func loadPreview() {
        guard !inputPath.isEmpty else { return }
        do {
            let sep = separator.first ?? ","
            let df = try DataFrame.readCSV(path: inputPath, separator: sep)
            previewInfo = "\(df.rowCount) rows × \(df.columnCount) cols — columns: \(df.columnNames.joined(separator: ", "))"
        } catch {
            previewInfo = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Daemon queries

    /// Available DataFrames partitioned by `kind`. Used to drive the
    /// grouped Picker in the GUI. Insertion order is stable (matches
    /// `availableInstances`); within a group, oldest-first.
    struct InstanceGroup: Identifiable {
        let id: String   // == kind
        let kind: String
        let entries: [DataFrameRegistry.Entry]
    }

    var groupedInstances: [InstanceGroup] {
        var orderedKinds: [String] = []
        var byKind: [String: [DataFrameRegistry.Entry]] = [:]
        for entry in availableInstances {
            if byKind[entry.kind] == nil { orderedKinds.append(entry.kind) }
            byKind[entry.kind, default: []].append(entry)
        }
        return orderedKinds.map { InstanceGroup(id: $0, kind: $0, entries: byKind[$0]!) }
    }

    /// Ask the daemon for its current list of resident DataFrames. Runs off
    /// the main queue so the UI doesn't block while the wire round trip
    /// happens (typically < 5 ms but could spike on a loaded system).
    func refreshInstances() {
        instanceStatus = "Querying daemon…"
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let resolved: String
            do {
                resolved = try Paths.socketPath()
            } catch {
                DispatchQueue.main.async {
                    self.availableInstances = []
                    self.instanceStatus = "Cannot resolve socket path: \(error.localizedDescription)"
                }
                return
            }

            do {
                let resp = try Client.sendRequest(.init(cmd: .list), socketPath: resolved, timeout: 3)
                guard resp.ok, case .list(let items) = resp.data else {
                    let msg = resp.error?.message ?? "daemon returned unexpected payload"
                    DispatchQueue.main.async {
                        self.availableInstances = []
                        self.instanceStatus = "Error: \(msg)"
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.availableInstances = items
                    if items.isEmpty {
                        self.instanceStatus = "Daemon is running, but no DataFrames are loaded."
                    } else {
                        let kinds = Set(items.map(\.kind)).sorted().joined(separator: ", ")
                        self.instanceStatus = "\(items.count) resident — kinds: \(kinds)"
                    }
                }
            } catch Client.ClientError.notRunning {
                DispatchQueue.main.async {
                    self.availableInstances = []
                    self.instanceStatus = "No daemon running. Start one with `swiftpandas server start`."
                }
            } catch {
                DispatchQueue.main.async {
                    self.availableInstances = []
                    self.instanceStatus = "Error talking to daemon: \(error)"
                }
            }
        }
    }

    /// Pull a CSV preview of the selected DataFrame from the daemon and
    /// display it in the result panel. The wire `show` reply is capped at
    /// the daemon's 1 MiB preview budget, which is plenty for a quick scan.
    func loadFromInstance(_ name: String) {
        statusMessage = "Loading \(name) from daemon…"
        hasError = false
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let resolved: String
            do {
                resolved = try Paths.socketPath()
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Cannot resolve socket: \(error)"
                    self.hasError = true
                }
                return
            }
            do {
                let resp = try Client.sendRequest(
                    .init(cmd: .show, name: name, head: 100),
                    socketPath: resolved,
                    timeout: 5
                )
                guard resp.ok, case .show(_, let rows, let cols, let csv, let truncated) = resp.data else {
                    let msg = resp.error?.message ?? "unexpected payload"
                    DispatchQueue.main.async {
                        self.statusMessage = msg
                        self.hasError = true
                    }
                    return
                }
                let header = "DataFrame `\(name)` (preview from daemon) — \(rows) rows × \(cols) cols\(truncated ? "  [truncated]" : "")\n\n"
                DispatchQueue.main.async {
                    self.resultCSV = csv
                    self.resultText = header + csv
                    self.statusMessage = "Loaded \(name) (\(rows) rows × \(cols) cols)"
                    self.hasError = false
                    self.timingInfo = ""
                }
            } catch Client.ClientError.notRunning {
                DispatchQueue.main.async {
                    self.statusMessage = "Daemon went away while loading \(name)."
                    self.hasError = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Error loading \(name): \(error)"
                    self.hasError = true
                }
            }
        }
    }

    func parseDSL() {
        let text = dslInput.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        do {
            let ops = try DSLParser.parse(text)
            operations = ops.map { op in
                let (type, args) = describeOp(op)
                return GUIOperation(opType: type, args: args)
            }
            dslInput = ""
        } catch {
            statusMessage = "DSL parse error: \(error.localizedDescription)"
            hasError = true
        }
    }

    func runPipeline() {
        guard !inputPath.isEmpty else { return }
        isRunning = true
        hasError = false
        statusMessage = "Running…"
        logOutput = ""

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let totalStart = CFAbsoluteTimeGetCurrent()
            var log = [String]()

            do {
                // Read
                let readStart = CFAbsoluteTimeGetCurrent()
                let sep = separator.first ?? ","
                let df = try DataFrame.readCSV(path: inputPath, separator: sep)
                let readTime = CFAbsoluteTimeGetCurrent() - readStart
                log.append("✓ read     │ \(URL(fileURLWithPath: inputPath).lastPathComponent)")
                log.append("           │ \(df.rowCount) rows × \(df.columnCount) cols  (\(Self.fmt(readTime)))")

                // Parse
                let parseStart = CFAbsoluteTimeGetCurrent()
                let dslChain = self.buildDSLChain()
                let ops = try DSLParser.parse(dslChain)
                let parseTime = CFAbsoluteTimeGetCurrent() - parseStart
                log.append("✓ parse    │ \(ops.count) operations  (\(Self.fmt(parseTime)))")

                // Execute
                let pipeStart = CFAbsoluteTimeGetCurrent()
                let runner = TransformRunner(operations: ops, verbose: false)
                let result = try runner.run(on: df)
                let pipeTime = CFAbsoluteTimeGetCurrent() - pipeStart

                for (i, op) in ops.enumerated() {
                    let (t, a) = self.describeOp(op)
                    log.append("  \(String(format: "%2d", i+1)). \(t.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))│ \(a)")
                }
                log.append("✓ pipeline │ \(Self.fmt(pipeTime))")

                let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
                log.append("═══════════════════════════════════════")
                log.append("✓ Success  │ \(df.rowCount) → \(result.rowCount) rows  total \(Self.fmt(totalTime))")

                let csv = result.toCSV(separator: self.separator)
                let table = result.description

                DispatchQueue.main.async {
                    self.resultText = table
                    self.resultCSV = csv
                    self.logOutput = log.joined(separator: "\n")
                    self.statusMessage = "\(result.rowCount) rows × \(result.columnCount) cols"
                    self.timingInfo = "read \(Self.fmt(readTime))  pipeline \(Self.fmt(pipeTime))  total \(Self.fmt(totalTime))"
                    self.hasError = false
                    self.isRunning = false
                }
            } catch {
                log.append("✗ Failed   │ \(error.localizedDescription)")

                DispatchQueue.main.async {
                    self.logOutput = log.joined(separator: "\n")
                    self.statusMessage = error.localizedDescription
                    self.hasError = true
                    self.isRunning = false
                }
            }
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "output.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try resultCSV.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "Exported to \(url.lastPathComponent)"
                hasError = false
            } catch {
                statusMessage = "Export failed: \(error.localizedDescription)"
                hasError = true
            }
        }
    }

    // MARK: - Helpers

    func buildDSLChain() -> String {
        if !dslInput.trimmingCharacters(in: .whitespaces).isEmpty {
            return dslInput
        }
        return operations.map { op in
            "\(op.opType.rawValue)(\(op.args))"
        }.joined(separator: " | ")
    }

    func describeOp(_ op: Operation) -> (GUIOpType, String) {
        switch op {
        case .filter(let expr):
            let v: String
            switch expr.value {
            case .number(let d): v = "\(d)"
            case .integer(let i): v = "\(i)"
            case .string(let s): v = "\"\(s)\""
            }
            return (.filter, "\(expr.column) \(expr.op.rawValue) \(v)")
        case .sort(let specs):
            return (.sort, specs.map { "\($0.column) \($0.direction.rawValue)" }.joined(separator: ", "))
        case .select(let cols): return (.select, cols.joined(separator: ", "))
        case .drop(let cols): return (.drop, cols.joined(separator: ", "))
        case .rename(let from, let to): return (.rename, "\(from) -> \(to)")
        case .head(let n): return (.head, "\(n)")
        case .tail(let n): return (.tail, "\(n)")
        case .groupBy(let cols): return (.groupby, cols.joined(separator: ", "))
        case .aggregate(let specs): return (.agg, specs.map { "\($0.fn.rawValue):\($0.col)" }.joined(separator: ", "))
        case .round(let col, let d): return (.round, "\(col), \(d)")
        case .derive(let name, _): return (.derive, "\(name) = …")
        case .cast(let col, let target): return (.cast, "\(col), \(target.rawValue)")
        }
    }

    static func fmt(_ seconds: Double) -> String {
        if seconds < 0.001 {
            return String(format: "%.0fµs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.1fms", seconds * 1_000)
        } else {
            return String(format: "%.2fs", seconds)
        }
    }
}
#endif
