import Foundation

/// CSV 导入的一行（Wallos 兼容格式）。
public struct ImportedSubscriptionRow: Sendable, Equatable {
    public let name: String
    public let amount: Decimal
    public let currency: String
    public let cycle: SubscriptionCycle
    public let nextRenewal: Date
    public let active: Bool

    public init(name: String, amount: Decimal, currency: String,
                cycle: SubscriptionCycle, nextRenewal: Date, active: Bool) {
        self.name = name
        self.amount = amount
        self.currency = currency
        self.cycle = cycle
        self.nextRenewal = nextRenewal
        self.active = active
    }
}

/// Wallos 兼容 CSV 导入器（§5.4）。
/// 标准列：Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active。多余列忽略，坏行跳过。
public enum SubscriptionCSVImporter {

    public static func parse(_ csv: String) throws -> [ImportedSubscriptionRow] {
        var rows: [ImportedSubscriptionRow] = []
        let records = parseCSVRecords(csv)
        guard let headerCols = records.first else { return [] }
        func idx(_ name: String) -> Int? { headerCols.firstIndex(of: name) }

        let nameI = idx("Name")
        let priceI = idx("Price")
        let currencyI = idx("Currency")
        let cycleTypeI = idx("Cycle_type")
        let nextI = idx("Next_payment")
        let activeI = idx("Active")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for cols in records.dropFirst() {
            guard cols.count == headerCols.count,
                  let nameI, let priceI, let currencyI, let cycleTypeI, let nextI,
                  nameI < cols.count, priceI < cols.count, currencyI < cols.count,
                  cycleTypeI < cols.count, nextI < cols.count,
                  let amount = Decimal(string: cols[priceI]),
                  let renewal = formatter.date(from: cols[nextI]) else { continue }
            let cycle: SubscriptionCycle
            switch cols[cycleTypeI].lowercased() {
            case "yearly", "annual": cycle = .yearly
            default: cycle = .monthly  // weekly/daily 等暂兜底为 monthly
            }
            let active = activeI.flatMap { i in i < cols.count ? (cols[i] != "0") : true } ?? true
            rows.append(ImportedSubscriptionRow(
                name: cols[nameI], amount: amount, currency: cols[currencyI],
                cycle: cycle, nextRenewal: renewal, active: active
            ))
        }
        return rows
    }

    /// RFC 4180 子集解析：支持逗号、换行与双引号转义。这样 DevHub 导出的
    /// 多行备注仍能再次导入，且不会因为一条带逗号的名称错位整行。
    private static func parseCSVRecords(_ csv: String) -> [[String]] {
        let characters = Array(csv)
        var records: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                case "\n":
                    row.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                    if !row.allSatisfy(\.isEmpty) { records.append(row) }
                    row = []
                case "\r":
                    break
                default:
                    field.append(character)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: .whitespaces))
            if !row.allSatisfy(\.isEmpty) { records.append(row) }
        }
        return records
    }
}

/// Wallos 兼容的订阅 CSV 导出器。基础七列可被 `SubscriptionCSVImporter`
/// 重新导入；Provider/Notes/ProjectID/ReminderDaysBefore 是 DevHub 扩展列，
/// 其他兼容工具可以安全忽略。
public enum SubscriptionCSVExporter {
    public static let header = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active,Provider,Notes,ProjectID,ReminderDaysBefore"

    public static func export(_ subscriptions: [SubscriptionSnapshot]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let rows = subscriptions.map { subscription in
            let cycleType = subscription.cycle == .yearly ? "yearly" : "monthly"
            return [
                subscription.name,
                NSDecimalNumber(decimal: subscription.amount).stringValue,
                subscription.currency,
                "1",
                cycleType,
                formatter.string(from: subscription.nextRenewal),
                subscription.active ? "1" : "0",
                subscription.provider,
                subscription.notes ?? "",
                subscription.projectId?.uuidString ?? "",
                String(subscription.reminderDaysBefore),
            ].map(escape).joined(separator: ",")
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
