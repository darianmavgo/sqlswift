import SwiftUI
import AppKit
import SQLDocCore

public struct SchemaSheetView: View {
    let doc: Doc
    let tableName: String
    let onDismiss: () -> Void

    @State private var schema: TableSchema?
    @State private var error: String?

    public init(doc: Doc, tableName: String, onDismiss: @escaping () -> Void) {
        self.doc = doc
        self.tableName = tableName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tableName).font(.system(size: 15, weight: .bold))
                    Text(schema?.type.capitalized ?? "…").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button("Copy DDL") {
                    if let ddl = schema?.ddl {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ddl, forType: .string)
                    }
                }
                .disabled(schema?.ddl.isEmpty ?? true)
                Button("Done", action: onDismiss).keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if let error {
                Text(error).foregroundColor(.secondary).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let schema {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        columnsSection(schema)
                        if !schema.foreignKeys.isEmpty { foreignKeysSection(schema) }
                        if !schema.indexes.isEmpty { indexesSection(schema) }
                        ddlSection(schema)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .task {
            do { schema = try await load() }
            catch { self.error = "Could not read schema: \(error.localizedDescription)" }
        }
    }

    private func load() async throws -> TableSchema {
        let d = doc, t = tableName
        return try await Task.detached { try d.tableSchema(for: t) }.value
    }

    // MARK: - Sections

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
    }

    private func columnsSection(_ sch: TableSchema) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("\(sch.columns.count) columns")
            VStack(spacing: 0) {
                ForEach(Array(sch.columns.enumerated()), id: \.element.id) { i, col in
                    HStack(spacing: 8) {
                        Text(col.name).font(.system(size: 12, weight: .medium)).frame(width: 180, alignment: .leading)
                        Text(col.type.isEmpty ? "—" : col.type)
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                        if col.pk {
                            tag("PK", .orange)
                            if col.name == sch.rowidAlias { tag("rowid", .secondary) }
                        }
                        if col.notNull { tag("NOT NULL", .secondary) }
                        Spacer()
                    }
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(i % 2 == 0 ? Color(NSColor.controlBackgroundColor).opacity(0.4) : .clear)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
        }
    }

    private func foreignKeysSection(_ sch: TableSchema) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("foreign keys")
            ForEach(sch.foreignKeys) { fk in
                HStack(spacing: 6) {
                    Text(fk.fromColumn).font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("\(fk.table).\(fk.toColumn)").font(.system(size: 12, design: .monospaced))
                    if !fk.onDelete.isEmpty && fk.onDelete != "NO ACTION" { tag("ON DELETE \(fk.onDelete)", .secondary) }
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
            }
        }
    }

    private func indexesSection(_ sch: TableSchema) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("indexes")
            ForEach(sch.indexes) { idx in
                HStack(spacing: 6) {
                    Image(systemName: idx.unique ? "key.fill" : "number")
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Text(idx.name).font(.system(size: 12, weight: .medium))
                    Text("(\(idx.columns.joined(separator: ", ")))")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    if idx.unique { tag("UNIQUE", .blue) }
                    if idx.partial { tag("partial", .secondary) }
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
            }
        }
    }

    private func ddlSection(_ sch: TableSchema) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("create statement")
            Text(sch.ddl.isEmpty ? "(none)" : sch.ddl)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(NSColor.separatorColor), lineWidth: 1))
        }
    }

    private func tag(_ s: String, _ color: Color) -> some View {
        Text(s).font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.18)).foregroundColor(color).cornerRadius(3)
    }
}
