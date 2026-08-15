import Foundation
import SwiftData
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "settings")

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-CN"
    case english = "en"

    static let preferenceKey = "devhub.appearance.language"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "跟随系统")
        case .simplifiedChinese: return String(localized: "简体中文")
        case .english: return String(localized: "English")
        }
    }

    private var appleLanguages: [String]? {
        switch self {
        case .system: return nil
        case .simplifiedChinese: return ["zh-Hans"]
        case .english: return ["en"]
        }
    }

    static func resolved(_ rawValue: String?) -> AppLanguage {
        guard let rawValue, let language = AppLanguage(rawValue: rawValue) else {
            return .simplifiedChinese
        }
        return language
    }

    static func stored(in preferences: UserDefaults) -> AppLanguage {
        resolved(preferences.string(forKey: preferenceKey))
    }

    static func apply(_ language: AppLanguage, to preferences: UserDefaults) {
        preferences.set(language.rawValue, forKey: preferenceKey)
        if let appleLanguages = language.appleLanguages {
            preferences.set(appleLanguages, forKey: "AppleLanguages")
        } else {
            preferences.removeObject(forKey: "AppleLanguages")
        }
    }

    static func applyStoredPreference(in preferences: UserDefaults) {
        apply(stored(in: preferences), to: preferences)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, tools, mcp, plugins
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "通用")
        case .tools:   return String(localized: "工具")
        case .mcp:     return String(localized: "MCP")
        case .plugins: return String(localized: "插件")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .tools:   return "wrench.and.screwdriver"
        case .mcp:     return "network"
        case .plugins: return "puzzlepiece.extension"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .general, .tools, .mcp, .plugins: return true
        }
    }

    var placeholderStage: PlaceholderStage? {
        nil
    }
}

@Observable
@MainActor
final class SettingsViewModel {
    var selectedTab: SettingsTab = .general
    var general = GeneralSettings()
    var tools: [Tool] = []
    var projects: [Project] = []
    var launchAtLoginState: LaunchAtLoginState = .disabled
    var isExportingLogs = false
    var languageChangeRequiresRestart = false

    var launchAtLoginRequested: Bool {
        launchAtLoginState.isRequested
    }

    struct GeneralSettings: Equatable {
        var projectsRoot: String = "~/Projects"
        var theme: String = "system"
        var locale: String = "zh-CN"
    }

    func consumeRequestedTab(from deps: AppDependencies) {
        guard let requested = deps.requestedSettingsTab else { return }
        selectedTab = requested
        deps.requestedSettingsTab = nil
    }

    func load(ctx: ModelContext, deps: AppDependencies) throws {
        let settings = try deps.ensureAppSettings(in: ctx)
        general.projectsRoot = settings.projectsRoot
        general.theme = settings.theme
        let storedLanguage = AppLanguage.resolved(settings.locale)
        general.locale = storedLanguage.rawValue
        deps.bootstrapPreferredLanguage(storedLanguage)
        languageChangeRequiresRestart = false
        launchAtLoginState = deps.launchAtLoginManager.state
        tools = try ctx.fetch(FetchDescriptor<Tool>(sortBy: [SortDescriptor(\.sortOrder)]))
        projects = try ctx.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)]))
    }

    func saveGeneral(ctx: ModelContext, deps: AppDependencies) throws {
        let id = AppSettings.singletonId
        let descriptor = FetchDescriptor<AppSettings>(predicate: #Predicate { $0.id == id })
        let settings = try ctx.fetch(descriptor).first ?? AppSettings(id: id)
        let previousLanguage = AppLanguage.resolved(settings.locale)
        let selectedLanguage = AppLanguage.resolved(general.locale)
        settings.projectsRoot = general.projectsRoot
        settings.theme = general.theme
        settings.locale = selectedLanguage.rawValue
        ctx.insert(settings)
        try ctx.save()
        deps.setPreferredLanguage(selectedLanguage)
        if previousLanguage != selectedLanguage {
            languageChangeRequiresRestart = true
        }
        NotificationCenter.default.post(
            name: Notification.Name("DevHubAppearanceChanged"),
            object: general.theme
        )
    }

    func restoreGeneralDefaults(ctx: ModelContext, deps: AppDependencies) throws {
        general = GeneralSettings()
        try saveGeneral(ctx: ctx, deps: deps)
    }

    var standardizedProjectsRoot: String {
        (general.projectsRoot as NSString).expandingTildeInPath
    }

    var projectsRootIsAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: standardizedProjectsRoot,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    func setLaunchAtLogin(_ enabled: Bool, deps: AppDependencies) throws {
        do {
            try deps.launchAtLoginManager.setEnabled(enabled)
            launchAtLoginState = deps.launchAtLoginManager.state
        } catch {
            launchAtLoginState = deps.launchAtLoginManager.state
            throw error
        }
    }

    func exportLastSevenDaysOfLogs(
        to destination: URL,
        privacyConfirmed: Bool,
        deps: AppDependencies
    ) async throws -> DevHubLogExportResult {
        guard privacyConfirmed else {
            throw SettingsActionError.logExportPrivacyConfirmationRequired
        }
        isExportingLogs = true
        defer { isExportingLogs = false }
        return try await deps.logExporter.exportLastSevenDays(to: destination)
    }

    func saveTools(ctx: ModelContext) throws {
        try ctx.save()
    }

    func restoreDefaultTools(ctx: ModelContext, deps: AppDependencies) throws {
        _ = try DefaultToolCatalog.restoreMissingDefaults(in: ctx)
        try load(ctx: ctx, deps: deps)
    }

    @discardableResult
    func addTool(kind: ToolKind, ctx: ModelContext) throws -> Tool {
        let baseName = kind == .app ? String(localized: "新 App") : String(localized: "新 CLI 工具")
        let usedNames = Set(tools.map { $0.name.lowercased() })
        var name = baseName
        var suffix = 2
        while usedNames.contains(name.lowercased()) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        let tool = Tool(
            name: name,
            kind: kind,
            launchCommand: "",
            workingDirMode: .projectRoot,
            injectMemory: false,
            injectionMode: .clipboard,
            enabled: true,
            sortOrder: (tools.map(\.sortOrder).max() ?? -1) + 1
        )
        tool.projects = projects
        ctx.insert(tool)
        try ctx.save()
        tools.append(tool)
        tools.sort { $0.sortOrder < $1.sortOrder }
        return tool
    }

    func usesBuiltInAdapter(_ tool: Tool) -> Bool {
        let name = tool.name.lowercased()
        let command = tool.launchCommand.lowercased()
        return ["codex", "claude", "claude code", "zcode", "z code", "kimi", "kimi chat", "vs code", "vscode"]
            .contains(name)
            || command.contains("chatgpt.app")
            || command.contains("zcode.app")
            || command.contains("zcode.cjs")
            || command.contains("visual studio code.app")
            || command.contains("kimi.app")
            || command.contains("claude")
    }

    func setBinding(tool: Tool, project: Project, enabled: Bool, ctx: ModelContext) throws {
        let alreadyBound = tool.projects.contains { $0.id == project.id }
        if enabled && !alreadyBound {
            tool.projects.append(project)
        } else if !enabled && alreadyBound {
            tool.projects.removeAll { $0.id == project.id }
        }
        try ctx.save()
    }

    func setEnvironmentVariable(tool: Tool, key: String, value: String, ctx: ModelContext) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            throw SettingsValidationError.invalidEnvironmentKey
        }
        var values = tool.envVars
        values[trimmed] = value
        tool.envVars = values
        try ctx.save()
    }

    func deleteEnvironmentVariable(tool: Tool, key: String, ctx: ModelContext) throws {
        var values = tool.envVars
        values.removeValue(forKey: key)
        tool.envVars = values
        try ctx.save()
    }

    func deleteTool(_ tool: Tool, ctx: ModelContext, deps: AppDependencies) throws {
        for key in tool.secretEnvKeys {
            _ = try? deps.keychain.delete(toolId: tool.id.uuidString, envKey: key)
        }
        ctx.delete(tool)
        try ctx.save()
        tools.removeAll { $0.id == tool.id }
    }

    // MARK: - Secret Env Keys（值不进 SwiftData、不进 UI 明文）

    func addSecretEnvKey(tool: Tool, envKey: String, value: String, deps: AppDependencies) throws {
        let normalizedKey = try validatedEnvironmentKey(envKey)
        guard !tool.secretEnvKeys.contains(normalizedKey) else {
            throw SettingsValidationError.duplicateSecretEnvironmentKey(normalizedKey)
        }
        let previousKeys = tool.secretEnvKeys
        let previousValue = try deps.keychain.get(toolId: tool.id.uuidString, envKey: normalizedKey)

        // 先写 Keychain，确认密钥已安全落盘后才修改并提交 SwiftData。
        // 这样 Keychain 拒绝写入时，列表不会短暂或永久显示一个不存在的密钥。
        try deps.keychain.set(toolId: tool.id.uuidString, envKey: normalizedKey, value: value)
        do {
            tool.secretEnvKeys.append(normalizedKey)
            try deps.modelContainer.mainContext.save()
        } catch {
            tool.secretEnvKeys = previousKeys
            if let previousValue {
                _ = try? deps.keychain.set(
                    toolId: tool.id.uuidString,
                    envKey: normalizedKey,
                    value: previousValue
                )
            } else {
                _ = try? deps.keychain.delete(toolId: tool.id.uuidString, envKey: normalizedKey)
            }
            throw error
        }
        logger.info("新增 secretEnvKey tool=\(tool.name, privacy: .public) key=\(normalizedKey, privacy: .public)")
    }

    func updateSecretEnvKey(tool: Tool, envKey: String, value: String, deps: AppDependencies) throws {
        let normalizedKey = try validatedEnvironmentKey(envKey)
        guard tool.secretEnvKeys.contains(normalizedKey) else {
            throw SettingsValidationError.missingSecretEnvironmentKey(normalizedKey)
        }
        try deps.keychain.set(toolId: tool.id.uuidString, envKey: normalizedKey, value: value)
        logger.info("更新 secretEnvKey tool=\(tool.name, privacy: .public) key=\(normalizedKey, privacy: .public)")
    }

    func deleteSecretEnvKey(tool: Tool, envKey: String, deps: AppDependencies) throws {
        let normalizedKey = try validatedEnvironmentKey(envKey)
        let previousKeys = tool.secretEnvKeys
        let previousValue = try deps.keychain.get(toolId: tool.id.uuidString, envKey: normalizedKey)

        // 删除也先处理 Keychain，再提交模型；失败时 UI 仍保留原密钥行。
        try deps.keychain.delete(toolId: tool.id.uuidString, envKey: normalizedKey)
        do {
            tool.secretEnvKeys.removeAll { $0 == normalizedKey }
            try deps.modelContainer.mainContext.save()
        } catch {
            tool.secretEnvKeys = previousKeys
            if let previousValue {
                _ = try? deps.keychain.set(
                    toolId: tool.id.uuidString,
                    envKey: normalizedKey,
                    value: previousValue
                )
            }
            throw error
        }
        logger.info("删除 secretEnvKey tool=\(tool.name, privacy: .public) key=\(normalizedKey, privacy: .public)")
    }

    /// UI 只检查 Keychain 条目是否真实存在，永不把明文返回给 View。
    /// 这样从备份恢复的 `secretEnvKeys` 不会被误显示为“已存储”。
    func secretDisplay(tool: Tool, envKey: String, deps: AppDependencies) -> String {
        let isStored = ((try? deps.keychain.get(
            toolId: tool.id.uuidString,
            envKey: envKey
        )) ?? nil) != nil
        return isStored
            ? "••••• " + String(localized: "已存储")
            : String(localized: "未设置")
    }

    private func validatedEnvironmentKey(_ key: String) throws -> String {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.range(
            of: #"^[A-Za-z_][A-Za-z0-9_]*$"#,
            options: .regularExpression
        ) != nil else {
            throw SettingsValidationError.invalidEnvironmentKey
        }
        return normalized
    }
}

enum SettingsValidationError: Error, LocalizedError {
    case invalidEnvironmentKey
    case duplicateSecretEnvironmentKey(String)
    case missingSecretEnvironmentKey(String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvironmentKey:
            return String(localized: "环境变量名只能包含字母、数字和下划线，且不能以数字开头。")
        case .duplicateSecretEnvironmentKey(let key):
            return String(localized: "密钥 \(key) 已存在，请使用“更新”。")
        case .missingSecretEnvironmentKey(let key):
            return String(localized: "密钥 \(key) 已不在工具配置中，请刷新设置后重试。")
        }
    }
}

enum SettingsActionError: Error, LocalizedError, Equatable {
    case logExportPrivacyConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .logExportPrivacyConfirmationRequired:
            return String(localized: "导出日志前必须确认隐私提示。")
        }
    }
}
