import Foundation

/// 把用户手动选择的 cwd 写入 SessionIndex（zcode rollout 无 cwd，必须用户绑定）。
/// 误用 artifacts 路径会污染项目归集——本 binder 不做任何推断，只接受显式用户输入。
public struct ZcodeCwdBinder: Sendable {
    public let writer: SessionIndexWriter

    public init(writer: SessionIndexWriter) { self.writer = writer }

    @discardableResult
    public func assign(toolSessionId: String, cwd: String) async throws -> Bool {
        let key = "zcode:\(toolSessionId)"
        return try await writer.updateCwd(identityKey: key, cwd: cwd)
    }

    /// 把 ZCode 会话归类到已注册项目。使用 stableId 而不是任意路径，
    /// 由 writer 同步维护 SessionIndex.project 与 projectCwd。
    @discardableResult
    public func assign(toolSessionId: String, projectStableId: String) async throws -> Bool {
        let key = "zcode:\(toolSessionId)"
        return try await writer.assignProject(identityKey: key, projectStableId: projectStableId)
    }
}
