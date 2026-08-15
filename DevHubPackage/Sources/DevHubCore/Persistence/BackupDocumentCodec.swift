import Foundation

/// 备份格式的唯一编码/解码入口，确保日期策略不会在 App UI 与 Core 测试之间漂移。
public enum BackupDocumentCodec {
    public static func encode(_ document: BackupDocument, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> BackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupDocument.self, from: data)
    }
}
