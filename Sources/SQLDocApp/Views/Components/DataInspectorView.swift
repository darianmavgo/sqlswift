import SwiftUI
import AppKit
import SQLDocCore

public struct DataInspectorView: View {
    let info: CellInspectInfo
    let onDismiss: () -> Void

    @State private var isPrettyJSON: Bool = false
    @State private var wrapLines: Bool = true
    @State private var copiedNotice: Bool = false

    public init(info: CellInspectInfo, onDismiss: @escaping () -> Void) {
        self.info = info
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(info.colName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.primary)

                        Text(info.colType.isEmpty ? "ANY" : info.colType)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color(NSColor.quaternaryLabelColor).opacity(0.3))
                            .cornerRadius(4)
                    }

                    Text("Table: \(info.tableName) · Row #\(info.rowOrdinal)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    Button(action: copyToClipboard) {
                        HStack(spacing: 4) {
                            Image(systemName: copiedNotice ? "checkmark" : "doc.on.doc")
                            Text(copiedNotice ? "Copied!" : "Copy")
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content Viewer
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch info.value {
                    case .null:
                        nullInspectorView

                    case .integer(let i):
                        numericInspectorView(title: "INTEGER", valueStr: "\(i)", intVal: i)

                    case .real(let r):
                        realInspectorView(r)

                    case .text(let s):
                        textInspectorView(s)

                    case .blob(let bytes):
                        blobInspectorView(byteCount: bytes)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 800, minHeight: 340, idealHeight: 440, maxHeight: 650)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    // MARK: - Text Inspector
    private func textInspectorView(_ text: String) -> some View {
        let isJSON = isValidJSON(text)
        let formattedText = isPrettyJSON ? prettyPrintJSON(text) : text

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(text.count) characters · \(text.utf8.count) bytes · \(text.components(separatedBy: .newlines).count) lines")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                if isJSON {
                    Toggle("Format JSON", isOn: $isPrettyJSON)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }

                Toggle("Wrap", isOn: $wrapLines)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }

            Text(formattedText)
                .font(.system(size: 12, design: isJSON ? .monospaced : .default))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .lineLimit(wrapLines ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(6)
        }
    }

    // MARK: - Number Inspector
    private func numericInspectorView(title: String, valueStr: String, intVal: Int64) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(valueStr)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                detailRow(label: "Hexadecimal", value: String(format: "0x%llX", UInt64(bitPattern: intVal)))
                detailRow(label: "Binary", value: String(intVal, radix: 2))

                if let dateStr = formatEpoch(intVal: intVal) {
                    detailRow(label: "Date (Local)", value: dateStr)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }

    private func formatEpoch(intVal: Int64) -> String? {
        if intVal > 978307200 && intVal < 2524608000 {
            let date = Date(timeIntervalSince1970: TimeInterval(intVal))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            formatter.timeZone = TimeZone.current
            return "\(formatter.string(from: date)) (epoch sec)"
        } else if intVal > 978307200000 && intVal < 2524608000000 {
            let date = Date(timeIntervalSince1970: TimeInterval(intVal / 1000))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            formatter.timeZone = TimeZone.current
            return "\(formatter.string(from: date)) (epoch ms)"
        }
        return nil
    }

    private func realInspectorView(_ val: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: "%g", val))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                detailRow(label: "Standard Float", value: "\(val)")
                detailRow(label: "Scientific", value: String(format: "%e", val))
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }

    // MARK: - BLOB Inspector
    private func blobInspectorView(byteCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("BLOB Binary Data")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(byteCount) bytes (\(formatBytes(byteCount)))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)

            Text("Binary objects can be inspected or exported from the main table.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - NULL Inspector
    private var nullInspectorView: some View {
        VStack(alignment: .center, spacing: 8) {
            Text("NULL")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
            Text("This database cell contains no value.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label + ":")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(info.value.displayText, forType: .string)
        copiedNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedNotice = false
        }
    }

    private func isValidJSON(_ str: String) -> Bool {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
            return false
        }
        guard let data = str.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) != nil
    }

    private func prettyPrintJSON(_ str: String) -> String {
        guard let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: prettyData, encoding: .utf8) else {
            return str
        }
        return result
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1048576 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.1f MB", Double(n) / 1048576.0)
    }
}
