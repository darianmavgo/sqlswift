import Foundation
import SQLDocCore

/// Dev-only remote control for the feedback loop. Polls `bin/ui-command.txt`
/// (beside the dev app, see `UILog`), runs each line through the same code paths
/// the UI uses, then deletes the file. Lets Claude drive the app and read
/// `ui-state.json` back without clicking.
///
/// Commands, one per line:
///   url <banquet url or path>      same as typing into the Banquet bar + Return
///   type <text>                    replace the bar's text as if typed (live-applies, no Return)
///   blur                           leave the bar (unapplied text reverts to the grid's URL)
///   sort <column> [desc]           ("sort -" clears)
///   filter <column> <op> <value>   op: contains equals notEquals startsWith greater less
///   clearfilters
///   display raw|trim|summary
///   hide <column> | showall
///   page next|prev|first|last
///   size <rows>                    page-size slice at the current offset
///   table <name>
///   cancel                         stop the page load in flight
///   scroll <row>                   bring a row of the loaded page to the top
///   inspect <row> <column>         open the cell inspector
///   layout table|cards            folder list layout
///   snapshot [name]                write the app window to bin/<name>.png (default ui-snapshot); no
///                                  macOS permission needed, the app draws itself
@MainActor
final class UICommandRunner {
    private var timer: Timer?
    private weak var appVM: AppViewModel?

    func start(appVM: AppViewModel) {
        #if DEBUG
        guard UILog.isEnabled, timer == nil, let path = UILog.commandFilePath else { return }
        self.appVM = appVM
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll(path) }
        }
        #endif
    }

    private func poll(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: path)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            run(line)
        }
    }

    private func run(_ line: String) {
        guard let appVM else { return }
        Self.execute(line, appVM: appVM)
    }

    /// Runs one command line against `appVM`. Shared with the headless UI tests
    /// (`Tests/SQLDocAppTests`) so they drive the app through the same verbs.
    static func execute(_ line: String, appVM: AppViewModel) {
        UILog.event("cmd", line)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""
        let vm = appVM.activeTableVM

        switch verb {
        case "url":
            appVM.openBanquet(urlString: rest, activeTableVM: vm)
        case "type":
            appVM.banquetBarInjectedText = rest
        case "suggest":
            // What the dropdown would offer for `rest`, without needing key events.
            let ctx = appVM.banquetSuggestContext(tableVM: vm)
            appVM.setSuggestionsSnapshot(BanquetSuggester.suggestions(for: rest, context: ctx).map(\.completion))
        case "go":
            // Same bookkeeping as submitting in the bar: remember where we were and where we went.
            let before = appVM.banquetURLString(for: vm)
            appVM.openBanquet(urlString: rest, activeTableVM: vm) {
                appVM.noteBanquetNavigation(from: before, to: appVM.banquetURLString(for: appVM.activeTableVM))
            }
        case "allrowscap":
            // Lower the "all rows" ceiling so the capped case is testable on a small table; 0 = default.
            vm?.allRowsCap = Int(rest).flatMap { $0 > 0 ? $0 : nil } ?? BehaviorConfig.windowAllRowsCap
        case "navreset":
            appVM.resetNavigation()
            appVM.setSuggestionsSnapshot([])
        case "recall":
            // ↑ / ↓ in the bar: `recall up|down`. Goes through the same state the key handler uses.
            if let t = appVM.recallStep(older: rest == "up", current: appVM.banquetBarText) {
                appVM.banquetBarInjectedText = t
            }
        case "back":
            appVM.navigateBack()
        case "forward":
            appVM.navigateForward()
        case "blur":
            appVM.isBanquetBarEditing = false
        case "table":
            appVM.selectedTableName = rest
        case "edit":
            if rest == "off" { appVM.edit.exit() } else if let e = appVM.activeDocEntry { appVM.edit.enter(e) }
        case "set", "setnull":
            // set <row> <col> <value…>   (row = 0-based index in the loaded page)
            let a = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard let vm, let page = vm.currentPage, a.count >= 2, let r = Int(a[0]), r < page.rows.count,
                  let c = page.columns.firstIndex(where: { $0.name == a[1] }), r < page.rowIDs.count else {
                UILog.event("cmd", "bad set", ["line": line]); return
            }
            if page.rows[r][c].isPartial {
                // Same as the grid: fetch the stored value first, then stage against it.
                Task { @MainActor in
                    if await vm.resolveFullValues(row: r, cols: [c]) { execute(line, appVM: appVM) }
                    else { UILog.event("edit", "stage rejected", ["error": "full value unavailable"]) }
                }
                return
            }
            let err = verb == "setnull"
                ? appVM.edit.stageNull(table: page.table, rowID: page.rowIDs[r], column: page.columns[c], original: page.rows[r][c])
                : appVM.edit.stage(table: page.table, rowID: page.rowIDs[r], column: page.columns[c],
                                   original: page.rows[r][c], text: a.count > 2 ? a[2] : "")
            if let err { UILog.event("edit", "stage rejected", ["error": err]) }
        case "cancel":
            vm?.cancelLoad()
        case "scroll":
            // scroll <row>   (0-based index in the loaded page) — brings that row to the top
            if let r = Int(rest) { vm?.scrollRowRequest = r }
        case "inspect":
            // inspect <row> <col>   opens the cell inspector, as a double-click does outside edit mode
            let a = rest.split(separator: " ").map(String.init)
            if let vm, a.count == 2, let r = Int(a[0]) { vm.inspectRequest = (row: r, column: a[1]) }
        case "newrow":
            // newrow [<col> <value…> …]   stages a new row; pairs fill its columns
            appVM.edit.newRow()
            appVM.edit.editingNewCell = nil
            if let vm, let id = appVM.edit.session?.buffer.allNewRows().last?.id {
                let a = rest.split(separator: " ").map(String.init)
                var i = 0
                while i + 1 < a.count {
                    if let col = vm.columns.first(where: { $0.name == a[i] }) {
                        _ = appVM.edit.stageNewRowCell(id: id, column: col, text: a[i + 1])
                    }
                    i += 2
                }
            }
        case "deleterow":
            // deleterow <row>   (0-based index in the loaded page)
            if let r = Int(rest) { appVM.selectedRowIndex = r; appVM.edit.deleteSelectedRows() }
        case "duplicaterow":
            if let r = Int(rest) { appVM.selectedRowIndex = r; Task { await appVM.edit.duplicateSelectedRow() } }
        case "layout":
            // layout table|cards   the folder list's layout (host chrome, not in the URL)
            if let style = FolderListStyle.allCases.first(where: { $0.rawValue.lowercased() == rest.lowercased() }) {
                appVM.folderListStyle = style
            }
        case "snapshot":
            #if DEBUG
            UIScreenshot.capture(name: rest)
            #endif
        case "commit":
            appVM.edit.commit()
        case "revert":
            appVM.edit.revert()
        case "undo":
            appVM.edit.undo()
        case "redo":
            appVM.edit.redo()
        case "sort":
            let a = rest.split(separator: " ").map(String.init)
            guard let col = a.first else { return }
            vm?.setSort(column: col == "-" ? nil : col, desc: a.dropFirst().first == "desc")
        case "filter":
            let a = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard a.count == 3, let op = ColumnFilter.Op(rawValue: a[1]) else {
                UILog.event("cmd", "bad filter", ["line": line]); return
            }
            vm?.setFilters([ColumnFilter(column: a[0], op: op, value: a[2])])
        case "clearfilters":
            vm?.clearFilters()
        case "display":
            if let k = DisplayKind(rawValue: rest) { vm?.setDisplayKind(k) }
        case "hide":
            vm?.setColumn(rest, hidden: true)
        case "showall":
            vm?.showAllColumns()
        case "page":
            guard let vm else { return }
            switch rest {
            case "next": appVM.paginateNext(tableVM: vm)
            case "prev": appVM.paginatePrevious(tableVM: vm)
            case "first": appVM.paginateFirst(tableVM: vm)
            case "last": appVM.paginateLast(tableVM: vm)
            default: break
            }
        case "size":
            if let vm, let n = Int(rest) { appVM.executeBanquetSlice(offset: vm.currentOffset, limit: n, tableVM: vm) }
        default:
            UILog.event("cmd", "unknown", ["line": line])
        }
    }
}
