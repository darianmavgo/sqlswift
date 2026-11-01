import Foundation
import SQLDocCore

/// Best-effort "make this value readable" formatting for the grid, keyed off the
/// column name and the value itself. Applied only when smart-format is on and
/// only when the guess is unambiguous, so raw data is never hidden by accident.
public enum CellFormat {
    public enum Kind: Sendable, Equatable {
        case none
        case time
        case size
        case mode
        case price        // open, high, low, close, equity, capital, price (2 fixed decimals)
        case signedPrice  // net_pnl, gross_pnl, net_profit, chg (+ / - with 2 fixed decimals & tone)
        case signedRate   // return_pct, cagr, vs_all_avg_return_pct, signal, alpha (+ / - with tone)
        case drawdown     // max_drawdown_pct, drawdown_pct (red tone when non-zero)
        case rate         // win_rate, prob_bull, prob_bear, alloc_pct (up to 4 decimals)
        case ratio        // sharpe_ratio, profit_factor, rsi14, avg_hold_days (2 decimals)
        case float        // generic float cleanup
        case json         // inline key:val pill summary for JSON text columns
    }

    public enum Tone: Sendable, Equatable {
        case neutral
        case positive
        case negative
    }

    private static let epochFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    /// Cheap one-time classification by column name — call this per column, not
    /// per cell, then pass the result to `pretty` and `tone`.
    public static func kind(forColumn name: String, isNumeric: Bool = false) -> Kind {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. System / Unix mode bits
        if n == "mode" || n.contains("permission") || n.contains("perms") { return .mode }

        // 2. Timestamps / epochs
        if n == "ts" || n == "time" || n == "date" || n == "timestamp"
            || n.hasSuffix("_at") || n.hasSuffix("_ts") || n.hasSuffix("_time")
            || n.hasSuffix("_date") || n.contains("epoch") { return .time }

        // 3. Byte counts
        if n.contains("size") && !n.contains("pct") || n.contains("bytes") { return .size }

        // 4. Drawdowns
        if n.contains("drawdown") { return .drawdown }

        // 5. Signed PnL / profit / price change
        if n == "pnl" || n.hasSuffix("_pnl") || n == "net_profit" || n == "chg" || n == "change" {
            return .signedPrice
        }

        // 6. Prices, OHLC, SMA/ATR, Capital, Equity, Cash, Dollars
        if n == "open" || n == "high" || n == "low" || n == "close" || n == "adj_close" || n == "adj close"
            || n == "prev_close" || n == "next_close" || n.hasPrefix("prev_close_")
            || n.hasPrefix("sma") && !n.contains("_vs_")
            || n.hasPrefix("atr") || n == "true_range" || n == "buylimit"
            || n == "price" || n.hasSuffix("_price")
            || n == "capital" || n.hasSuffix("_capital")
            || n == "equity" || n.hasSuffix("_equity")
            || n == "cash" || n == "invested" || n == "buying_power"
            || n.hasPrefix("margin_") || n.hasPrefix("dividend_") || n.hasSuffix("_dividends")
            || n.hasSuffix("_dollars") || n.hasSuffix("_amount") || n.hasPrefix("commission") || n.hasSuffix("_commission_paid") {
            return .price
        }

        // 7. Signed returns, CAGR, signals, alpha, relative deltas
        if n.contains("return") || n == "cagr" || n == "signal" || n == "alpha"
            || n.contains("_vs_") || n == "mae_pct" || n == "mfe_pct"
            || n == "avg_mae" || n == "avg_mfe" {
            return .signedRate
        }

        // 8. Unsigned rates / probabilities / allocations / thresholds
        if n == "win_rate" || n.hasPrefix("prob_") || n.hasSuffix("_pct")
            || n == "close_near_high" || n.hasSuffix("threshold") {
            return .rate
        }

        // 9. Ratios, Sharpe/Sortino/Calmar, Profit Factor, RSI, Holding Days
        if n == "profit_factor" || n.hasSuffix("_ratio") || n == "ratio"
            || n.hasPrefix("sharpe") || n.hasPrefix("sortino") || n.hasPrefix("calmar")
            || n.hasPrefix("omega") || n.hasPrefix("ulcer") || n == "beta"
            || n.hasPrefix("rsi") || n.hasPrefix("vol_ratio") || n.hasPrefix("avg_gain") || n.hasPrefix("avg_loss")
            || n == "avg_hold_days" || n == "avg_holding_days" || n == "total_calendar_years" {
            return .ratio
        }

        // 10. Known JSON metadata columns
        if n == "facts" || n == "metadata" || n == "class_counts" || n.hasSuffix("_json") || n == "json" {
            return .json
        }

        return isNumeric ? .float : .none
    }

    /// Semantic tone for signed metrics (positive = green, negative = red).
    public static func tone(value: SQLiteValue, kind: Kind) -> Tone {
        guard let d = value.doubleValue, !d.isNaN else { return .neutral }
        switch kind {
        case .signedPrice, .signedRate:
            if d > 1e-9 { return .positive }
            if d < -1e-9 { return .negative }
            return .neutral
        case .drawdown:
            if abs(d) > 1e-9 { return .negative }
            return .neutral
        default:
            return .neutral
        }
    }

    /// Returns a formatted display string, or nil to fall back to the raw text.
    public static func pretty(value: SQLiteValue, kind: Kind) -> String? {
        switch value {
        case .integer(let i):
            switch kind {
            case .mode where i >= 0 && i <= 0o7777:
                return permissions(i)
            case .time where i > 100_000_000 && i < 4_102_444_800:
                return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i)))
            case .time where i > 100_000_000_000 && i < 4_102_444_800_000:
                return epochFormatter.string(from: Date(timeIntervalSince1970: Double(i) / 1000))
            case .size where i >= 1024:
                return byteSize(i)
            default:
                return nil
            }

        case .real(let r):
            switch kind {
            case .time where r > 100_000_000 && r < 4_102_444_800:
                return epochFormatter.string(from: Date(timeIntervalSince1970: r))
            case .price:
                return SQLiteValueFormat.realString(r, decimals: 2, trimTrailingZeros: false)
            case .signedPrice:
                return SQLiteValueFormat.realString(r, decimals: 2, trimTrailingZeros: false, forceSign: true)
            case .signedRate:
                let dec = abs(r) > 0 && abs(r) < 1.0 ? 4 : 2
                return SQLiteValueFormat.realString(r, decimals: dec, trimTrailingZeros: true, forceSign: true)
            case .drawdown:
                let dec = abs(r) > 0 && abs(r) < 1.0 ? 4 : 2
                return SQLiteValueFormat.realString(r, decimals: dec, trimTrailingZeros: false)
            case .rate:
                let dec = abs(r) > 0 && abs(r) < 1.0 ? 4 : 2
                return SQLiteValueFormat.realString(r, decimals: dec, trimTrailingZeros: true)
            case .ratio:
                return SQLiteValueFormat.realString(r, decimals: 2, trimTrailingZeros: false)
            case .float:
                return SQLiteValueFormat.realString(r)
            default:
                return nil
            }

        case .text(let s):
            if kind == .json || (s.utf8.count >= 4 && s.hasPrefix("{") && s.hasSuffix("}")) {
                return compactJSONSummary(s)
            }
            return nil

        default:
            return nil
        }
    }

    /// Condenses a flat JSON object like `{"-2":47,"-1":286,"0":345}` or
    /// `{"signal_symbol":"VOO","close":707.47,"streak":2}` into a clean inline summary.
    public static func compactJSONSummary(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}"),
              trimmed.utf8.count <= 2048,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !obj.isEmpty else {
            return nil
        }

        // Sort keys numerically if all keys parse as numbers (e.g. class_counts "-2", "-1", "0", "1", "2"),
        // otherwise alphabetically.
        let keys = obj.keys.sorted { a, b in
            if let na = Double(a), let nb = Double(b) { return na < nb }
            return a < b
        }

        var parts: [String] = []
        parts.reserveCapacity(min(keys.count, 6))
        for k in keys.prefix(6) {
            guard let v = obj[k] else { continue }
            let valStr: String
            if let num = v as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    valStr = num.boolValue ? "true" : "false"
                } else if floor(num.doubleValue) == num.doubleValue && abs(num.doubleValue) < 1e12 {
                    valStr = SQLiteValueFormat.integerString(num.int64Value)
                } else {
                    valStr = SQLiteValueFormat.realString(num.doubleValue)
                }
            } else if let str = v as? String {
                valStr = str
            } else {
                continue
            }
            parts.append("\(k): \(valStr)")
        }
        guard !parts.isEmpty else { return nil }
        let suffix = keys.count > 6 ? " · …" : ""
        return parts.joined(separator: " · ") + suffix
    }

    static func permissions(_ mode: Int64) -> String {
        let bits = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        let u = Int((mode >> 6) & 7), g = Int((mode >> 3) & 7), o = Int(mode & 7)
        return "\(bits[u])\(bits[g])\(bits[o]) (\(String(mode, radix: 8)))"
    }

    static func byteSize(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(n), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n) B" : String(format: "%.1f %@", v, units[i])
    }
}
