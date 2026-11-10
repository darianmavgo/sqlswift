import SwiftUI
import AppKit
import SQLDocCore

@MainActor
final class QueryConsoleModel: ObservableObject {
    let doc: Doc
    @Published var sql: String
    @Published var result: QueryResult?
    @Published var error: String?
    @Published var running = false
    private var token: CancelToken?

    init(doc: Doc, seed: String) {
        self.doc = doc
        self.sql = seed
    }

    func run() {
        let text = sql
        running = true
        error = nil
        let d = doc
        let token = CancelToken()
        self.token = token
        // Result cells are one-line previews, so long text is cut at the grid's cap.
        let control = QueryControl(
            budgetMs: BehaviorConfig.queryConsoleBudgetMs,
            token: token,
            maxTextBytes: BehaviorConfig.textCellFetchMaxBytes,
            maxResultBytes: BehaviorConfig.queryResultMaxBytes
        )
        UILog.event("console", "run", ["chars": text.count])
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try d.runQuery(text, control: control)
                await MainActor.run {
                    guard let self, self.token === token else { return }
                    self.result = r; self.error = nil; self.running = false
                }
            } catch {
                await MainActor.run {
                    guard let self, self.token === token else { return }
                    UILog.event("console", "stopped", ["error": error.localizedDescription])
                    self.error = error.localizedDescription; self.running = false
                }
            }
        }
    }

    /// Stops the statement in flight. The query returns `.cancelled` and the
    /// previous result, if any, stays on screen.
    func cancel() {
        guard running else { return }
        UILog.event("console", "cancel")
        token?.cancel()
    }
}

public struct QueryConsoleView: View {
    @StateObject private var model: QueryConsoleModel
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    public init(doc: Doc, seedTable: String, seedSQL: String? = nil, onDismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: QueryConsoleModel(
            doc: doc,
            seed: seedSQL ?? (seedTable.isEmpty ? "SELECT 1" : "SELECT * FROM \(Doc.quoteIdent(seedTable)) LIMIT 100")))
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Query console").font(.system(size: 13, weight: .semibold))
                Text("read-only · SELECT / WITH / PRAGMA / EXPLAIN")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button {
                        model.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.fill").font(.system(size: 12))
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        model.run()
                    } label: {
                        Label("Run", systemImage: "play.fill").font(.system(size: 12))
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                // Closing the console must not leave its query holding the connection.
                Button("Done") { model.cancel(); onDismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            TextEditor(text: $model.sql)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 160)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))

            Divider()

            if let error = model.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error).font(.system(size: 11, design: .monospaced)).foregroundColor(.primary)
                    Spacer()
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
            }

            if let r = model.result {
                resultBar(r)
                Divider()
                ResultGridView(result: r)
            } else if model.error == nil {
                Text("⌘↵ to run").font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(minWidth: 620, idealWidth: 820, minHeight: 460, idealHeight: 620)
    }

    private func resultBar(_ r: QueryResult) -> some View {
        HStack(spacing: 10) {
            Text("\(r.rows.count) row\(r.rows.count == 1 ? "" : "s")\(r.truncated ? " (capped at \(Doc.queryRowCap))" : "")")
                .font(.system(size: 11, weight: .medium))
            Text(formatMicros(r.micros)).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
            if r.hasClippedText {
                Text("long values cut at \(BehaviorConfig.textCellFetchMaxBytes.formatted()) bytes, marked …")
                    .font(.system(size: 11)).foregroundColor(.orange)
            }
            Spacer()
            Button {
                let tsv = ([r.columns.joined(separator: "\t")] +
                           r.rows.map { $0.map { $0.displayText }.joined(separator: "\t") }).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tsv, forType: .string)
            } label: { Label("Copy as TSV", systemImage: "doc.on.doc").font(.system(size: 11)) }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func formatMicros(_ m: Int64) -> String {
        m < 1000 ? "\(m) µs" : String(format: "%.2f ms", Double(m) / 1000)
    }
}

/// A lightweight scrollable grid for console results (no virtualization needed —
/// the row cap keeps it bounded).
struct ResultGridView: View {
    let result: QueryResult

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(result.columns.enumerated()), id: \.offset) { _, name in
                        Text(name).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .frame(minWidth: 60, alignment: .leading)
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                Divider()
                ForEach(Array(result.text.prefix(2000).enumerated()), id: \.offset) { ri, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.text)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .frame(minWidth: 60, alignment: .leading)
                        }
                    }
                    .background(ri % 2 == 0 ? Color(NSColor.controlBackgroundColor).opacity(0.25) : .clear)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
