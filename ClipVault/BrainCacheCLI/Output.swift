import Foundation

/// Output mode: machine-readable (NDJSON) vs. human-readable (table).
///
/// Auto-detects based on stdout: when piped to a file or another process,
/// emits one JSON object per line. When attached to a terminal, prints a
/// padded table. Both can be forced via `--json` / `--table`.
enum OutputMode: String {
    case auto, json, table

    func resolve() -> ResolvedOutputMode {
        switch self {
        case .json: return .json
        case .table: return .table
        case .auto: return isatty(fileno(stdout)) != 0 ? .table : .json
        }
    }
}

enum ResolvedOutputMode {
    case json, table
}

/// Renders a collection of `Encodable` rows according to the chosen output mode.
struct Renderer {
    let mode: ResolvedOutputMode

    init(_ mode: OutputMode) {
        self.mode = mode.resolve()
    }

    private static let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        // NDJSON: one record per line, no whitespace inside the line.
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    /// Streams NDJSON one row at a time (callers that want true streaming can
    /// invoke `writeOne` themselves). For table mode we buffer into the
    /// `TablePrinter` so column widths can stabilise.
    func write<T: Encodable>(_ rows: [T], columns: [TableColumn<T>]) {
        switch mode {
        case .json:
            for row in rows {
                writeOne(row)
            }
        case .table:
            let printer = TablePrinter()
            for col in columns { printer.addColumn(col.title) }
            for row in rows {
                printer.addRow(columns.map { $0.value(row) })
            }
            printer.flush()
        }
    }

    func writeOne<T: Encodable>(_ value: T) {
        guard let data = try? Self.jsonEncoder.encode(value),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
    }

    /// Writes a single non-row value (e.g. an `info` payload) — pretty JSON for
    /// terminals, compact NDJSON for pipes.
    func writeObject<T: Encodable>(_ value: T) {
        switch mode {
        case .json:
            writeOne(value)
        case .table:
            let pretty = JSONEncoder()
            pretty.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            pretty.dateEncodingStrategy = .iso8601
            if let data = try? pretty.encode(value),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        }
    }
}

/// Definition of one column in a table-mode render.
struct TableColumn<T> {
    let title: String
    let value: (T) -> String
}

/// Stdout table printer with right-padded columns.
final class TablePrinter {
    private var titles: [String] = []
    private var rows: [[String]] = []

    func addColumn(_ title: String) { titles.append(title) }
    func addRow(_ cells: [String]) { rows.append(cells) }

    func flush() {
        guard !titles.isEmpty else { return }
        var widths = titles.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // Cap each column so long content doesn't blow up the line. We
        // truncate with an ellipsis; users that need full content should use
        // `show` or pipe to JSON.
        let maxWidth = 80
        widths = widths.map { min($0, maxWidth) }

        print(format(cells: titles, widths: widths))
        print(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
        for row in rows {
            print(format(cells: row, widths: widths))
        }
    }

    private func format(cells: [String], widths: [Int]) -> String {
        zip(cells, widths).map { cell, width in
            let truncated = cell.count > width ? String(cell.prefix(max(width - 1, 1))) + "…" : cell
            return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
        }.joined(separator: "  ")
    }
}

/// Shared ISO-8601 formatter used across the CLI's human-readable output.
let cliIsoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
