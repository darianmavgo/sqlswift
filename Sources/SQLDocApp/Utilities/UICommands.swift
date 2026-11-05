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
        case "blur":
            appVM.isBanquetBarEditing = false
        case "table":
            appVM.selectedTableName = rest
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
