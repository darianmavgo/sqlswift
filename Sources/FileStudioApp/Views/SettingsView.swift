import SwiftUI
import FileStudioKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var from = ""
    @State private var target = ""
    @State private var prefix = ""
    @State private var freeLocal = ""
    @State private var seeded = false

    var body: some View {
        let s = model.snapshot
        let locals = s.sources.filter(\.isLocal)
        let remotes = s.sources.filter { !$0.isLocal }
        Form {
            Section("Database") {
                LabeledContent("File") {
                    Text(model.dbPath ?? "—").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("Worker") { WorkerBadge() }
                Button("Open Another Database…") { OpenPanel.chooseDatabase(model) }
            }

            Section {
                Picker("Back up", selection: $from) {
                    Text("Choose…").tag("")
                    ForEach(locals) { Text("\($0.name)  (\(Fmt.count($0.fileCount)) files)").tag($0.name) }
                }
                Picker("To", selection: $target) {
                    Text("Choose…").tag("")
                    Section("Cloud") {
                        ForEach(remotes) { Text("\($0.name)  — \($0.remote)").tag($0.name) }
                    }
                    // a folder on another disk is a valid backup too; never the source itself
                    let otherLocals = locals.filter { $0.name != from }
                    if !otherLocals.isEmpty {
                        Section("Folder on this Mac") {
                            ForEach(otherLocals) { Text("\($0.name)  — \(RouteLine.tilde($0.remote))").tag($0.name) }
                        }
                    }
                }
                TextField("Folder inside the backup", text: $prefix, prompt: Text("optional, e.g. Documents"))
                if let t = s.sources.first(where: { $0.name == target }) {
                    LabeledContent("Files will go to") {
                        Text(t.remote + (prefix.isEmpty ? "" : "/" + prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
                            .textSelection(.enabled).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Save Backup Choice") {
                        let (t, p, f) = (target, prefix, from)
                        model.perform("set backup") { try $0.setBackup(target: t, prefix: p, from: f) }
                    }
                    .disabled(target.isEmpty || from.isEmpty || (target == s.config.target && prefix == s.config.prefix && from == s.config.from))
                }
            } header: {
                Text("What to back up")
            } footer: {
                Text("Sources are added with the filestudio command (source add / index). A backup's folder must match how files are laid out in the bucket, or nothing will be found as already copied.")
            }

            Section {
                Picker("Free space on", selection: Binding(get: { freeLocal }, set: { v in
                    freeLocal = v
                    model.perform("default_local") { try $0.setSetting("default_local", v) }
                })) {
                    Text("Choose…").tag("")
                    ForEach(locals) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Reclaim")
            } footer: {
                Text("The local source Find Files I Can Delete looks at. It is checked against the backup chosen above.")
            }

            Section {
                IntSetting(key: "bk_transfers", label: "Parallel files", range: 1...256, step: 8,
                           help: "Many small files: more is faster. 64 sent 2,004 files in 20 s on R2 (4 took 222 s).")
                IntSetting(key: "bk_big_transfers", label: "Parallel big files", range: 1...32, step: 1,
                           help: "Files over the multipart cutoff. Each one buffers chunk size × parts at once.")
                IntSetting(key: "bk_s3_upload_concurrency", label: "Parts per big file", range: 1...32, step: 1,
                           help: "Parts of one big file uploaded at the same time.")
                ChoiceSetting(key: "bk_s3_chunk_size", label: "Part size", choices: ["8M", "16M", "32M", "64M", "128M"])
                IntSetting(key: "bk_retries", label: "Retries per file", range: 0...10, step: 1,
                           help: "With backoff; a file that still fails is listed under Needs attention, the run goes on.")
                let big = Double(ByteSize.parse(model.snapshot.settings["bk_s3_chunk_size"] ?? "32M"))
                    * Double(Int(model.snapshot.settings["bk_s3_upload_concurrency"] ?? "8") ?? 8)
                    * Double(Int(model.snapshot.settings["bk_big_transfers"] ?? "4") ?? 4)
                LabeledContent("Upload memory, worst case") { Text(Fmt.bytes(Int64(big))).foregroundStyle(.secondary) }
            } header: {
                Text("Speed")
            } footer: {
                Text("Applies to the next backup.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: seed)
        .onChange(of: s.config) { seeded = false; seed() }
    }

    private func seed() {
        guard !seeded else { return }
        let c = model.snapshot.config
        from = c.from
        target = c.target
        prefix = c.prefix
        freeLocal = c.freeLocal
        seeded = true
    }
}

private struct IntSetting: View {
    @Environment(AppModel.self) private var model
    let key: String
    let label: String
    let range: ClosedRange<Int>
    let step: Int
    let help: String

    var body: some View {
        let value = Int(model.snapshot.settings[key] ?? "") ?? Self.defaults[key] ?? range.lowerBound
        Stepper(value: Binding(get: { value }, set: { v in
            let v = min(max(v, range.lowerBound), range.upperBound)
            model.perform(key) { try $0.setSetting(key, String(v)) }
        }), in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .help(help)
    }

    static let defaults = ["bk_transfers": 64, "bk_big_transfers": 4, "bk_s3_upload_concurrency": 8, "bk_retries": 3]
}

private struct ChoiceSetting: View {
    @Environment(AppModel.self) private var model
    let key: String
    let label: String
    let choices: [String]

    var body: some View {
        Picker(label, selection: Binding(get: { model.snapshot.settings[key] ?? "32M" }, set: { v in
            model.perform(key) { try $0.setSetting(key, v) }
        })) {
            ForEach(choices, id: \.self) { Text($0).tag($0) }
        }
    }
}

enum ByteSize {
    /// rclone size syntax: 32M, 1G, 512K.
    static func parse(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        guard let last = t.last else { return 0 }
        let mult: Int64 = switch last { case "K": 1 << 10; case "M": 1 << 20; case "G": 1 << 30; default: 1 }
        let digits = mult == 1 ? t : String(t.dropLast())
        return (Int64(digits) ?? 0) * mult
    }
}
