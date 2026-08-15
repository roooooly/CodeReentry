import Foundation
import SwiftData

/// 工具注册（§4.1）。
/// secretEnvKeys 只存 key 名（如 "ANTHROPIC_API_KEY"），值走 Keychain（Task 12）。
/// 因此 SwiftData 导出/日志天然不含敏感值（§4.3 §5.4 §8.4 §8.5）。
@Model
public final class Tool {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var kindRaw: String
    public var launchCommand: String
    public var workingDirModeRaw: String
    public var customWorkingDir: String?
    public var injectMemory: Bool
    public var injectionModeRaw: String
    public var injectionArgs: [String]?
    public var envVars: [String: String]
    public var secretEnvKeys: [String]
    public var mcpServerRef: String?
    public var enabled: Bool
    public var sortOrder: Int
    /// 一键安装命令（`brew install` / `npm install -g` 后半段或完整命令）。
    /// 为空表示该工具只能手动安装（`installMethod == .manual`）。
    public var installCommand: String?
    /// 安装方式 rawValue（`InstallMethod`）。可选以兼容旧库轻量迁移；读取兜底 `.manual`。
    public var installMethodRaw: String?
    /// 覆盖默认 PATH 探测的绝对路径；为空则用 `launchCommand` 推断是否已安装。
    public var detectPath: String?
    /// 下载页 URL（manual 安装方式下，DevHub 打开此页）。
    public var downloadURL: String?

    @Relationship
    public var projects: [Project] = []

    public var kind: ToolKind {
        get { ToolKind(rawValue: kindRaw) ?? .cli }
        set { kindRaw = newValue.rawValue }
    }
    public var workingDirMode: WorkingDirMode {
        get { WorkingDirMode(rawValue: workingDirModeRaw) ?? .projectRoot }
        set { workingDirModeRaw = newValue.rawValue }
    }
    public var injectionMode: InjectionMode {
        get { InjectionMode(rawValue: injectionModeRaw) ?? .cliFlag }
        set { injectionModeRaw = newValue.rawValue }
    }
    public var installMethod: InstallMethod {
        get {
            guard let raw = installMethodRaw, let m = InstallMethod(rawValue: raw) else { return .manual }
            return m
        }
        set { installMethodRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ToolKind,
        launchCommand: String,
        workingDirMode: WorkingDirMode,
        customWorkingDir: String? = nil,
        injectMemory: Bool = false,
        injectionMode: InjectionMode,
        injectionArgs: [String]? = nil,
        envVars: [String: String] = [:],
        secretEnvKeys: [String] = [],
        mcpServerRef: String? = nil,
        enabled: Bool = true,
        sortOrder: Int,
        installCommand: String? = nil,
        installMethod: InstallMethod = .manual,
        detectPath: String? = nil,
        downloadURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kindRaw = kind.rawValue
        self.launchCommand = launchCommand
        self.workingDirModeRaw = workingDirMode.rawValue
        self.customWorkingDir = customWorkingDir
        self.injectMemory = injectMemory
        self.injectionModeRaw = injectionMode.rawValue
        self.injectionArgs = injectionArgs
        self.envVars = envVars
        self.secretEnvKeys = secretEnvKeys
        self.mcpServerRef = mcpServerRef
        self.enabled = enabled
        self.sortOrder = sortOrder
        self.installCommand = installCommand
        self.installMethodRaw = installMethod.rawValue
        self.detectPath = detectPath
        self.downloadURL = downloadURL
    }
}
