import Foundation
import SwiftData

/// DevHub 自带的工具目录。
///
/// 新安装的数据库必须至少有一组可用工具，否则项目注册完成后 Tools tab 永远为空，
/// 而设置页也没有任何对象可供绑定。目录只在数据库完全没有 Tool 时自动播种；用户
/// 主动删除后的恢复走 `restoreMissingDefaults(in:)`，避免每次启动都复活已删除项。
public enum DefaultToolCatalog {

    public static let defaultNames = [
        "Claude Code", "Codex", "ZCode", "Kimi", "OpenCode", "Gemini CLI",
        "GitHub Copilot CLI", "Aider", "Cline", "Goose", "Pi", "VS Code"
    ]

    /// 仅当数据库没有任何工具时创建内置工具，并绑定到已有项目。
    @MainActor
    @discardableResult
    public static func seedIfNeeded(in context: ModelContext) throws -> [Tool] {
        let existing = try context.fetch(FetchDescriptor<Tool>(sortBy: [SortDescriptor(\.sortOrder)]))
        guard existing.isEmpty else { return existing }
        return try insertMissingDefaults(in: context)
    }

    /// 用户显式选择“恢复内置工具”时调用。按内置名称补齐缺失项，不删除或覆盖自定义配置。
    @MainActor
    @discardableResult
    public static func restoreMissingDefaults(in context: ModelContext) throws -> [Tool] {
        try insertMissingDefaults(in: context)
    }

    /// Restore one named built-in without reviving other defaults the user removed.
    /// New catalog entries use this during a one-time app migration.
    @MainActor
    @discardableResult
    public static func restoreDefault(named name: String, in context: ModelContext) throws -> Tool? {
        let existing = try context.fetch(FetchDescriptor<Tool>())
        if let match = existing.first(where: { canonicalName($0.name) == canonicalName(name) }) {
            return match
        }
        guard let tool = makeDefaults().first(where: {
            canonicalName($0.name) == canonicalName(name)
        }) else { return nil }

        // Append on upgraded catalogs instead of rewriting a user's established order.
        if let maximumSortOrder = existing.map(\.sortOrder).max() {
            tool.sortOrder = maximumSortOrder + 1
        }
        tool.projects = try context.fetch(FetchDescriptor<Project>())
        context.insert(tool)
        try context.save()
        return tool
    }

    @MainActor
    private static func insertMissingDefaults(in context: ModelContext) throws -> [Tool] {
        let existing = try context.fetch(FetchDescriptor<Tool>())
        let existingNames = Set(existing.map { canonicalName($0.name) })
        let projects = try context.fetch(FetchDescriptor<Project>())

        var result = existing
        for tool in makeDefaults() where !existingNames.contains(canonicalName(tool.name)) {
            tool.projects = projects
            context.insert(tool)
            result.append(tool)
        }
        try context.save()
        return result.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 把当前启用的工具绑定到新注册项目，使首次使用无需再去设置页逐项勾选。
    @MainActor
    public static func bindEnabledTools(to project: Project, in context: ModelContext) throws {
        let enabled = try context.fetch(FetchDescriptor<Tool>(
            predicate: #Predicate { $0.enabled == true },
            sortBy: [SortDescriptor(\.sortOrder)]
        ))
        project.tools = enabled
    }

    @MainActor
    private static func makeDefaults() -> [Tool] {
        [
            Tool(
                name: "Claude Code", kind: .cli, launchCommand: "claude",
                workingDirMode: .projectRoot, injectMemory: true,
                injectionMode: .cliFlag, enabled: true, sortOrder: 0,
                installCommand: "install -g @anthropic-ai/claude-code",
                installMethod: .npm,
                downloadURL: "https://docs.claude.com/en/docs/claude-code/setup"
            ),
            Tool(
                name: "Codex", kind: .cli,
                launchCommand: "/Applications/ChatGPT.app/Contents/Resources/codex",
                workingDirMode: .projectRoot, injectMemory: true,
                injectionMode: .positionalArg, enabled: true, sortOrder: 1,
                installCommand: nil,
                installMethod: .manual,
                detectPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
                downloadURL: "https://chatgpt.com/download"
            ),
            Tool(
                name: "ZCode", kind: .cli,
                launchCommand: "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
                workingDirMode: .projectRoot, injectMemory: true,
                injectionMode: .positionalArg, enabled: true, sortOrder: 2,
                installCommand: nil,
                installMethod: .manual,
                detectPath: "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs",
                downloadURL: "https://z.ai/zcode"
            ),
            Tool(
                name: "Kimi", kind: .app,
                launchCommand: "/Applications/Kimi.app",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .clipboard, enabled: true, sortOrder: 3,
                installCommand: "install --cask kimichat",
                installMethod: .brew,
                downloadURL: "https://kimi.moonshot.cn/download"
            ),
            Tool(
                name: "OpenCode", kind: .cli, launchCommand: "opencode",
                workingDirMode: .projectRoot, injectMemory: true,
                injectionMode: .positionalArg, enabled: true, sortOrder: 4,
                installCommand: "install -g opencode-ai",
                installMethod: .npm,
                downloadURL: "https://opencode.ai/docs/"
            ),
            Tool(
                name: "Gemini CLI", kind: .cli, launchCommand: "gemini",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 5,
                installCommand: "install -g @google/gemini-cli",
                installMethod: .npm,
                downloadURL: "https://github.com/google-gemini/gemini-cli"
            ),
            Tool(
                name: "GitHub Copilot CLI", kind: .cli, launchCommand: "copilot",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 6,
                installCommand: "install copilot-cli",
                installMethod: .brew,
                downloadURL: "https://github.com/github/copilot-cli"
            ),
            Tool(
                name: "Aider", kind: .cli, launchCommand: "aider",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 7,
                installCommand: nil,
                installMethod: .manual,
                downloadURL: "https://aider.chat/docs/install.html"
            ),
            Tool(
                name: "Cline", kind: .cli, launchCommand: "cline",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 8,
                installCommand: "install -g cline",
                installMethod: .npm,
                downloadURL: "https://docs.cline.bot/getting-started/installing-cline"
            ),
            Tool(
                name: "Goose", kind: .cli, launchCommand: "goose",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 9,
                installCommand: "install block-goose-cli",
                installMethod: .brew,
                downloadURL: "https://block.github.io/goose/docs/getting-started/installation/"
            ),
            Tool(
                name: "Pi", kind: .cli, launchCommand: "pi",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .cliFlag, enabled: true, sortOrder: 10,
                installCommand: "install -g --ignore-scripts @earendil-works/pi-coding-agent",
                installMethod: .npm,
                downloadURL: "https://github.com/earendil-works/pi/tree/v0.84.2/packages/coding-agent"
            ),
            Tool(
                name: "VS Code", kind: .app,
                launchCommand: "/Applications/Visual Studio Code.app",
                workingDirMode: .projectRoot, injectMemory: false,
                injectionMode: .clipboard, enabled: true, sortOrder: 11,
                installCommand: "install --cask visual-studio-code",
                installMethod: .brew,
                downloadURL: "https://code.visualstudio.com/Download"
            ),
        ]
    }

    private static func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
