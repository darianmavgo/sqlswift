import SwiftUI

public struct JumpToRowView: View {
    @ObservedObject var tableVM: TableViewModel
    let onDismiss: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    public init(tableVM: TableViewModel, onDismiss: @escaping () -> Void) {
        self.tableVM = tableVM
        self.onDismiss = onDismiss
    }

    private var total: Int64 { tableVM.filteredCount ?? tableVM.tableCount.rows }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to row").font(.system(size: 13, weight: .semibold))
            HStack {
                TextField("row number", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .focused($focused)
                    .onSubmit(go)
                if total > 0 {
                    Text("of \(total)").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction)
                    .disabled(Int64(text) == nil)
            }
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func go() {
        guard let n = Int64(text) else { return }
        tableVM.jumpToOrdinal(n)
        onDismiss()
    }
}
