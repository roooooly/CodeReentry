import Foundation
import SwiftData

public enum ModelContainerFactory {

    public struct RecoveryResult {
        public let container: ModelContainer
        /// 非 nil 表示原存储打不开，已完整移动到此目录后重建空库。
        public let recoveredStoreDirectory: URL?

        public init(container: ModelContainer, recoveredStoreDirectory: URL?) {
            self.container = container
            self.recoveredStoreDirectory = recoveredStoreDirectory
        }
    }

    @MainActor
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(DevHubSchemaV1.models)
        let config: ModelConfiguration
        if inMemory {
            // 测试模式：纯内存，不落盘
            config = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        } else {
            // 生产模式：落盘到 §4.2 指定的 ~/Library/Application Support/DevHub/DevHub.store
            config = ModelConfiguration(
                schema: schema,
                url: storeURL(),
                allowsSave: true,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// 生产启动入口：先正常打开；若失败且磁盘上确有 store/sidecar，则把整组文件
    /// 移到可恢复目录，再创建新库。绝不删除损坏库，也不把持久化失败静默降级。
    @MainActor
    public static func makeRecoveringContainer(
        at url: URL = storeURL(),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> RecoveryResult {
        do {
            return RecoveryResult(
                container: try makeDiskContainer(at: url),
                recoveredStoreDirectory: nil
            )
        } catch let originalError {
            let candidates = storeFiles(for: url, fileManager: fileManager)
            guard !candidates.isEmpty else { throw originalError }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let recoveryDirectory = url.deletingLastPathComponent()
                .appendingPathComponent(
                    "RecoveredStore-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8))",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
            do {
                for file in candidates {
                    try fileManager.moveItem(
                        at: file,
                        to: recoveryDirectory.appendingPathComponent(file.lastPathComponent)
                    )
                }
                let container = try makeDiskContainer(at: url)
                return RecoveryResult(
                    container: container,
                    recoveredStoreDirectory: recoveryDirectory
                )
            } catch {
                // 若重建失败，尽力把已移动文件放回原位，保留原错误上下文。
                for created in storeFiles(for: url, fileManager: fileManager) {
                    try? fileManager.removeItem(at: created)
                }
                if let moved = try? fileManager.contentsOfDirectory(
                    at: recoveryDirectory,
                    includingPropertiesForKeys: nil
                ) {
                    for file in moved {
                        let destination = url.deletingLastPathComponent()
                            .appendingPathComponent(file.lastPathComponent)
                        if !fileManager.fileExists(atPath: destination.path) {
                            try? fileManager.moveItem(at: file, to: destination)
                        }
                    }
                }
                try? fileManager.removeItem(at: recoveryDirectory)
                throw error
            }
        }
    }

    public static func storeURL() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DevHub", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("DevHub.store")
    }

    public static func makeContainer(configurations: [ModelConfiguration]) throws -> ModelContainer {
        let schema = Schema(DevHubSchemaV1.models)
        return try ModelContainer(for: schema, configurations: configurations)
    }

    @MainActor
    private static func makeDiskContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema(DevHubSchemaV1.models)
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func storeFiles(for url: URL, fileManager: FileManager) -> [URL] {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent
        return ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { candidate in
            let name = candidate.lastPathComponent
            return name == prefix || name.hasPrefix(prefix + "-")
        }
    }
}
