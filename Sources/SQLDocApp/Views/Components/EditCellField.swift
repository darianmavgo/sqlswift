import SwiftUI
import SQLDocCore

/// The inline cell editor (docs/BanquetEditStyle.md rule 5). Shows the raw value.
/// Return stages and moves down, Tab stages and moves right, Esc cancels,
/// ⌥⌫ sets NULL. A value that doesn't parse stays open with a red border.
struct EditCellField: View {
    enum Move { case down, right, none }

    let initial: String
    let width: CGFloat
    let height: CGFloat
    let zoom: CGFloat
    let palette: GridPalette
    /// Returns an error message to keep the editor open, or nil once staged.
    let onSubmit: (String, Move) -> String?
    let onNull: () -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(initial: String, width: CGFloat, height: CGFloat, zoom: CGFloat, palette: GridPalette,
         onSubmit: @escaping (String, Move) -> String?, onNull: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initial = initial; self.width = width; self.height = height; self.zoom = zoom
        self.palette = palette; self.onSubmit = onSubmit; self.onNull = onNull; self.onCancel = onCancel
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12 * zoom, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(width: width, height: height)
            .background(palette.page)
            .overlay(Rectangle().stroke(error == nil ? Color.accentColor : Color.red, lineWidth: 2))
            .help(error ?? "Return: stage · Tab: stage and move right · Esc: cancel · ⌥⌫: NULL")
            .focused($focused)
            .onAppear { focused = true }
            .onSubmit { error = onSubmit(text, .down) }
            .onKeyPress(.tab) { error = onSubmit(text, .right); return .handled }
            .onKeyPress(.escape) { onCancel(); return .handled }
            .onKeyPress(.delete, phases: .down) { press in
                guard press.modifiers.contains(.option) else { return .ignored }
                onNull(); return .handled
            }
            .onChange(of: text) { _, _ in error = nil }
    }
}
