import SwiftUI
import SQLDocCore

/// Row operations and Apply / Discard for an edit session (docs/HighRepEdit.md). It is its own
/// strip under the Banquet bar, not part of it: nothing here reads or changes the URL.
struct EditToolbarView: View {
    @ObservedObject var appVM: AppViewModel
    let tableVM: TableViewModel?

    private var edit: EditViewModel { appVM.edit }

    private var summary: String {
        var parts: [String] = []
        if edit.updateCount > 0 { parts.append("\(edit.updateCount) changed") }
        if edit.insertCount > 0 { parts.append("\(edit.insertCount) new") }
        if edit.deleteCount > 0 { parts.append("\(edit.deleteCount) deleted") }
        return parts.isEmpty ? "No pending changes" : parts.joined(separator: " · ")
    }

    var body: some View {
        let canEdit = edit.canEditActiveTable
        HStack(spacing: 6) {
            Button { edit.newRow() } label: { Label("Row", systemImage: "plus") }
                .help("Add a row (⌥⌘N)")
                .disabled(!canEdit)
            Button { edit.deleteSelectedRows() } label: { Label("Row", systemImage: "minus") }
                .help("Delete the selected or ⌘-marked rows (⌘⌫)")
                .disabled(!canEdit)
            Button { Task { await edit.duplicateSelectedRow() } } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .help("Duplicate the selected row (⌘D)")
                .disabled(!canEdit)

            Divider().frame(height: 14)

            Button { edit.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo a staged change (⌘Z)").disabled(!edit.canUndo)
            Button { edit.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)").disabled(!edit.canRedo)

            Spacer()

            Text(summary)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(edit.isDirty ? .orange : .secondary)

            Button("SQL…") { edit.showSQLPreview = true }
                .help("Preview the statements Apply will run")
                .disabled(!edit.isDirty)
            Button("Discard") { edit.revert() }
                .help("Throw away every pending change")
                .disabled(!edit.isDirty)
            Button("Apply") { edit.commit() }
                .help("Write every pending change in one transaction (⌘S)")
                .disabled(!edit.isDirty)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.08))
        .overlay(Divider(), alignment: .bottom)
    }
}

/// The exact statements an Apply would run, for review. Display only.
struct SQLPreviewSheet: View {
    @ObservedObject var edit: EditViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending SQL").font(.headline)
            Text("Run in one transaction when you Apply. Values are shown inline here; the real statements bind parameters.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            ScrollView {
                Text(edit.sqlPreview.isEmpty ? "-- nothing pending" : edit.sqlPreview.joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(edit.sqlPreview.joined(separator: "\n"), forType: .string)
                }
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 320)
    }
}

/// Shown when a document is open but not being edited, so the edit session is discoverable.
/// Host chrome only; the Banquet bar is untouched.
struct EditEntryStrip: View {
    @ObservedObject var appVM: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button { appVM.edit.toggle() } label: { Label("Edit Data", systemImage: "pencil") }
                .help("Start an edit session (⌥⌘E). The file stays untouched until you Apply.")
            Text("Read-only · start an edit session to change, add or delete rows")
                .font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 3)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
}
