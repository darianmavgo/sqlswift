import SwiftUI
import FileStudioKit

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var tab = 0
    @State private var query = ""
    @State private var deleted: [DeletedEntry] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Log").tag(0)
                Text("Backup Runs").tag(1)
                Text("Deleted Files").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(12)
            Divider()
            switch tab {
            case 0: logTable
            case 1: runsTable
            default: deletedTable
            }
        }
    }

    private var logTable: some View {
        Table(model.snapshot.jobLog) {
            TableColumn("When") { e in Text(Fmt.ago(e.at)).help(e.at) }.width(120)
            TableColumn("Action") { e in Text(Humanize.action(e.action)) }.width(130)
            TableColumn("Result") { e in StateChip(state: e.state) }.width(90)
            TableColumn("Message") { e in Text(Humanize.message(e.message)).lineLimit(2).help(e.message) }
        }
        .alternatingRowBackgrounds(.disabled) // no empty striped rows under a short list
    }

    private var runsTable: some View {
        Table(model.snapshot.runs) {
            TableColumn("Run") { r in Text("\(r.id)").monospacedDigit() }.width(50)
            TableColumn("State") { r in StateChip(state: r.state) }.width(100)
            TableColumn("Started") { r in Text(Fmt.ago(r.startedAt)).help(r.startedAt) }.width(120)
            TableColumn("Proven") { r in Text("\(Fmt.count(r.filesDone)) / \(Fmt.count(r.filesTotal))").monospacedDigit() }.width(120)
            TableColumn("Sent") { r in Text(Fmt.bytes(r.bytesUploaded)).monospacedDigit() }.width(90)
            TableColumn("Failed") { r in Text(Fmt.count(r.filesFailed)).monospacedDigit() }.width(60)
            TableColumn("Destination") { r in Text(r.dest).lineLimit(1).truncationMode(.middle).help(r.dest) }
        }
        .alternatingRowBackgrounds(.disabled) // no empty striped rows under a short list
    }

    private var deletedTable: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search deleted paths", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                if searching { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(10)
            Table(deleted) {
                TableColumn("When") { d in Text(Fmt.ago(d.at)).help(d.at) }.width(110)
                TableColumn("File") { d in Text(d.path).lineLimit(1).truncationMode(.middle).help(d.path) }
                TableColumn("Size") { d in Text(Fmt.bytes(d.size)).monospacedDigit() }.width(76)
                TableColumn("Reason") { d in Text(d.reason).lineLimit(1) }.width(140)
                TableColumn("Copy kept at") { d in Text(d.keepCopy).lineLimit(1).truncationMode(.head).textSelection(.enabled).help(d.keepCopy) }
            }
            .alternatingRowBackgrounds(.disabled) // no empty striped rows under a short list
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200)) // debounce typing
            guard !Task.isCancelled, let db = model.database else { return }
            searching = true
            let q = query
            let rows = await Task.detached(priority: .userInitiated) { (try? db.deleted(matching: q)) ?? [] }.value
            if !Task.isCancelled { deleted = rows }
            searching = false
        }
    }
}
