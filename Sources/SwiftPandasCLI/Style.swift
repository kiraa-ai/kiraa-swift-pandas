import Foundation

/// ANSI styling for stderr output. All escape codes are emitted only when
/// stderr is attached to a terminal so logs to files stay clean.
enum Style {
    static let isTerminal = isatty(STDERR_FILENO) != 0

    static var bold: String    { isTerminal ? "\u{1B}[1m" : "" }
    static var dim: String     { isTerminal ? "\u{1B}[2m" : "" }
    static var reset: String   { isTerminal ? "\u{1B}[0m" : "" }
    static var cyan: String    { isTerminal ? "\u{1B}[36m" : "" }
    static var green: String   { isTerminal ? "\u{1B}[32m" : "" }
    static var yellow: String  { isTerminal ? "\u{1B}[33m" : "" }
    static var red: String     { isTerminal ? "\u{1B}[31m" : "" }
    static var magenta: String { isTerminal ? "\u{1B}[35m" : "" }
}

/// Write a single line to stderr.
func logStderr(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

/// Format a duration in seconds as a compact human-readable string
/// ("245µs", "12.3ms", "1.42s", "2m17.4s").
func formatTime(_ seconds: Double) -> String {
    if seconds < 0.001 {
        return String(format: "%.0fµs", seconds * 1_000_000)
    } else if seconds < 1.0 {
        return String(format: "%.1fms", seconds * 1_000)
    } else if seconds < 60.0 {
        return String(format: "%.2fs", seconds)
    } else {
        let mins = Int(seconds) / 60
        let secs = seconds - Double(mins * 60)
        return String(format: "%dm%.1fs", mins, secs)
    }
}

/// Format an integer count as "1.2M", "45.0K", or "873".
func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000)
    } else if n >= 10_000 {
        return String(format: "%.1fK", Double(n) / 1_000)
    }
    return "\(n)"
}

/// Format a byte count as "1.5 GB", "240 MB", "3.1 KB", or "512 B".
func formatBytes(_ bytes: Int) -> String {
    let units: [(Double, String)] = [
        (1_073_741_824, "GB"),
        (1_048_576,     "MB"),
        (1_024,         "KB"),
    ]
    for (scale, suffix) in units {
        if Double(bytes) >= scale {
            return String(format: "%.1f %@", Double(bytes) / scale, suffix)
        }
    }
    return "\(bytes) B"
}
