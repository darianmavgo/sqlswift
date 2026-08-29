import SwiftUI
import SQLDocCore

public struct StartPageView: View {
    @ObservedObject var appVM: AppViewModel
    @State private var pathInput: String = ""

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.system(size: 54, weight: .light))
                    .foregroundColor(.accentColor)

                Text("sqldoc")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.primary)

                Text("Drop a SQLite database anywhere on this page, or open one.")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 12) {
                Button(action: { appVM.showOpenPanel() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 14))
                        Text("Open a database…")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // Direct path input
                HStack {
                    Image(systemName: "terminal")
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    TextField("…or paste a database file path", text: $pathInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit {
                            if !pathInput.isEmpty {
                                appVM.open(path: pathInput)
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: 360)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
            }

            // Recent databases list
            if !appVM.recentItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT DATABASES")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 4) {
                        ForEach(appVM.recentItems.prefix(6)) { item in
                            Button(action: { appVM.open(path: item.path) }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "externaldrive.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.primary)
                                        Text(item.path)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(BenchmarkRunner.formatBytes(item.size))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.primary)
                                        if item.tableCount > 0 {
                                            Text("\(item.tableCount) tables")
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 520)
                }
                .padding(.top, 12)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
