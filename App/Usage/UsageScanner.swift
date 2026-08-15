import Foundation
import DevHubCore

/// 用量扫描协调器（§订阅用量与成本）。
///
/// 用户进入用量页时按需扫描 Claude + Codex 的本地 JSONL，聚合成 UsageSnapshot 缓存在内存。
/// 提供 `refresh()` 手动刷新与 `refreshIfStale()` 按需刷新（避免频繁全量扫描）。
///
/// 纯本地读取，不触网络与凭据。扫描放后台 task，不阻塞 UI。
@MainActor
@Observable
public final class UsageScanner {
    /// 当前缓存的聚合快照。
    public private(set) var snapshot: UsageSnapshot?
    /// Codex 最近额度（5h/7d）。
    public private(set) var codexRateLimit: CodexRateLimitSnapshot?
    public private(set) var isScanning = false
    public private(set) var lastScannedAt: Date?

    private let claudeReader: ClaudeUsageReader
    private let codexReader: CodexUsageReader
    /// 返回当前注册项目的根路径列表（用于按 cwd 归桶到 perProject）。
    /// 闭包形式注入，避免 Core 层依赖 SwiftData；调用时机在后台扫描时。
    private let projectPathsProvider: @Sendable () -> [String]

    public init(claudeReader: ClaudeUsageReader = ClaudeUsageReader(),
                codexReader: CodexUsageReader = CodexUsageReader(),
                projectPathsProvider: @escaping @Sendable () -> [String] = { [] }) {
        self.claudeReader = claudeReader
        self.codexReader = codexReader
        self.projectPathsProvider = projectPathsProvider
    }

    /// 全量重新扫描（手动刷新用）。
    public func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        // Claude 与 Codex 并发读取；Codex 单次遍历同时抽 usage 与 rate_limit。
        async let claude = claudeReader.readAll()
        async let codexBundle = codexReader.readAllAndRateLimit()
        let claudeRecords = await claude
        let codex = await codexBundle
        let records = claudeRecords + codex.records
        // 在后台 actor 外捕获项目路径快照（只读 fetch），避免随 SwiftData 变动。
        let projectPaths = await Task.detached { self.projectPathsProvider() }.value
        snapshot = UsageAggregator.aggregate(records, projectPaths: projectPaths)
        codexRateLimit = codex.rateLimit
        lastScannedAt = Date()
    }

    /// 若距上次扫描超过阈值则刷新（进入用量页面时按需）。
    public func refreshIfStale(olderThan seconds: TimeInterval = 300) async {
        if let last = lastScannedAt, Date().timeIntervalSince(last) < seconds { return }
        await refresh()
    }

    /// 仅测试用：直接注入预构建快照，避免扫描真实文件。
    public func injectSnapshotForTesting(_ snap: UsageSnapshot, rateLimit: CodexRateLimitSnapshot? = nil) {
        snapshot = snap
        codexRateLimit = rateLimit
        lastScannedAt = Date()
    }
}
