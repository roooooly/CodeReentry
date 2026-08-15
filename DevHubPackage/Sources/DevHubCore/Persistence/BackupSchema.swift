import Foundation

/// 备份文档（§8.4）。`devhub-backup-YYYYMMDD.json`。
/// 脱敏：Tool 只含普通 envVars + secretEnvKeys 名（无值）；SessionIndex 不含 preview。
public struct BackupDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var exportedAt: Date
    public var projects: [BackupProject]
    public var subscriptions: [BackupSubscription]
    public var platformAccounts: [BackupPlatformAccount]
    public var tools: [BackupTool]
    public var sessionPreviews: [BackupSessionPreview]
    public var settings: BackupAppSettings?
    /// v2：项目 × 平台账号发布状态。可选以兼容早期 v1 备份。
    public var platformBindings: [BackupPlatformBinding]?

    public init(schemaVersion: Int, exportedAt: Date,
                projects: [BackupProject], subscriptions: [BackupSubscription],
                platformAccounts: [BackupPlatformAccount], tools: [BackupTool],
                sessionPreviews: [BackupSessionPreview], settings: BackupAppSettings?,
                platformBindings: [BackupPlatformBinding]? = nil) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.projects = projects
        self.subscriptions = subscriptions
        self.platformAccounts = platformAccounts
        self.tools = tools
        self.sessionPreviews = sessionPreviews
        self.settings = settings
        self.platformBindings = platformBindings
    }
}

public struct BackupProject: Codable, Sendable, Equatable {
    public var stableId: String
    public var name: String
    public var path: String
    public var tags: [String]
    public var group: String?
    public var isPinned: Bool
    public var status: String?
    public var version: String?

    public init(stableId: String, name: String, path: String, tags: [String], group: String?, isPinned: Bool,
                status: String? = nil, version: String? = nil) {
        self.stableId = stableId; self.name = name; self.path = path
        self.tags = tags; self.group = group; self.isPinned = isPinned
        self.status = status; self.version = version
    }
}

public struct BackupSubscription: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String
    public var provider: String
    public var amount: Decimal
    public var currency: String
    public var cycle: String
    public var nextRenewal: Date
    public var reminderDaysBefore: Int
    public var notes: String?
    public var projectStableId: String?
    public var active: Bool?

    public init(id: UUID? = nil, name: String, provider: String, amount: Decimal, currency: String,
                cycle: String, nextRenewal: Date, reminderDaysBefore: Int,
                notes: String?, projectStableId: String?, active: Bool? = nil) {
        self.id = id; self.name = name; self.provider = provider; self.amount = amount
        self.currency = currency; self.cycle = cycle; self.nextRenewal = nextRenewal
        self.reminderDaysBefore = reminderDaysBefore; self.notes = notes
        self.projectStableId = projectStableId
        self.active = active
    }
}

public struct BackupPlatformAccount: Codable, Sendable, Equatable {
    public var id: UUID?
    public var platform: String
    public var displayName: String
    public var loginUrl: String

    public init(id: UUID? = nil, platform: String, displayName: String, loginUrl: String) {
        self.id = id; self.platform = platform; self.displayName = displayName; self.loginUrl = loginUrl
    }
}

public struct BackupTool: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String
    public var kind: String
    public var launchCommand: String
    public var envVars: [String: String]      // 仅普通，无密钥
    public var secretEnvKeys: [String]        // 仅 key 名，无值
    public var enabled: Bool
    public var workingDirMode: String?
    public var customWorkingDir: String?
    public var injectMemory: Bool?
    public var injectionMode: String?
    public var injectionArgs: [String]?
    public var mcpServerRef: String?
    public var sortOrder: Int?
    public var projectStableIds: [String]?
    public var installCommand: String?
    public var installMethod: String?
    public var detectPath: String?
    public var downloadURL: String?

    public init(id: UUID? = nil, name: String, kind: String, launchCommand: String,
                envVars: [String: String], secretEnvKeys: [String], enabled: Bool,
                workingDirMode: String? = nil, customWorkingDir: String? = nil,
                injectMemory: Bool? = nil, injectionMode: String? = nil,
                injectionArgs: [String]? = nil, mcpServerRef: String? = nil,
                sortOrder: Int? = nil, projectStableIds: [String]? = nil,
                installCommand: String? = nil, installMethod: String? = nil,
                detectPath: String? = nil, downloadURL: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.launchCommand = launchCommand
        self.envVars = envVars; self.secretEnvKeys = secretEnvKeys; self.enabled = enabled
        self.workingDirMode = workingDirMode; self.customWorkingDir = customWorkingDir
        self.injectMemory = injectMemory; self.injectionMode = injectionMode
        self.injectionArgs = injectionArgs; self.mcpServerRef = mcpServerRef
        self.sortOrder = sortOrder; self.projectStableIds = projectStableIds
        self.installCommand = installCommand; self.installMethod = installMethod
        self.detectPath = detectPath; self.downloadURL = downloadURL
    }
}

public struct BackupSessionPreview: Codable, Sendable, Equatable {
    public var tool: String
    public var toolSessionId: String
    public var projectStableId: String?
    public var startedAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    // 不含 preview 字段（脱敏，spec §8.4）

    public init(tool: String, toolSessionId: String, projectStableId: String?,
                startedAt: Date, updatedAt: Date, messageCount: Int) {
        self.tool = tool; self.toolSessionId = toolSessionId
        self.projectStableId = projectStableId
        self.startedAt = startedAt; self.updatedAt = updatedAt; self.messageCount = messageCount
    }
}

public struct BackupPlatformBinding: Codable, Sendable, Equatable {
    public var id: UUID?
    public var projectStableId: String
    public var accountId: UUID?
    public var accountPlatform: String
    public var accountDisplayName: String
    public var publishStatus: String
    public var publishUrl: String?
    public var publishNotes: String?
    public var lastPublishedAt: Date?

    public init(id: UUID? = nil, projectStableId: String, accountId: UUID? = nil,
                accountPlatform: String, accountDisplayName: String,
                publishStatus: String, publishUrl: String?, publishNotes: String?,
                lastPublishedAt: Date?) {
        self.id = id; self.projectStableId = projectStableId; self.accountId = accountId
        self.accountPlatform = accountPlatform; self.accountDisplayName = accountDisplayName
        self.publishStatus = publishStatus; self.publishUrl = publishUrl
        self.publishNotes = publishNotes; self.lastPublishedAt = lastPublishedAt
    }
}

public struct BackupAppSettings: Codable, Sendable, Equatable {
    public var projectsRoot: String
    public var enabledPlugins: [String]
    public var theme: String
    public var sidebarWidth: Double
    public var locale: String

    public init(projectsRoot: String, enabledPlugins: [String], theme: String,
                sidebarWidth: Double, locale: String) {
        self.projectsRoot = projectsRoot; self.enabledPlugins = enabledPlugins
        self.theme = theme; self.sidebarWidth = sidebarWidth; self.locale = locale
    }
}

/// 路径重新定位结果（§8.4）。
public enum RelocationResult: Equatable, Sendable {
    case resolved(String)          // 找到的新 path
    case missing(stableId: String)  // 需用户手动指定
}

/// 导入时路径重新定位（§8.4）。
/// 1. 原路径存在 → 用原路径
/// 2. 不存在 → 在 searchRoots 下扫 `.devhub/project.local.json` 的 stableId 匹配
/// 3. 仍找不到 → missing(stableId)
public struct PathRelocator: @unchecked Sendable {
    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func resolve(stableId: String, originalPath: String, searchRoots: [String]) -> RelocationResult {
        if fileManager.fileExists(atPath: originalPath) {
            return .resolved(originalPath)
        }
        for root in searchRoots {
            if let found = scanForStableId(stableId: stableId, in: root) {
                return .resolved(found)
            }
        }
        return .missing(stableId: stableId)
    }

    private func scanForStableId(stableId: String, in rootPath: String) -> String? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: rootPath) else { return nil }
        for entry in entries {
            let projDir = (rootPath as NSString).appendingPathComponent(entry)
            let localJson = (projDir as NSString).appendingPathComponent(".devhub/project.local.json")
            guard fileManager.fileExists(atPath: localJson),
                  let data = fileManager.contents(atPath: localJson),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["stableId"] as? String,
                  sid == stableId else { continue }
            return projDir
        }
        return nil
    }
}
