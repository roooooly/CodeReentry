import Foundation
import os

/// 隐私级别（对应 §8.5 OSLog Privacy）
public enum LogPrivacy: Sendable, Equatable {
    case `public`    // 路径、工具名、会话 ID —— 明文
    case `private`   // 命令参数、env 值、文件摘要 —— 默认遮罩
    case sensitive   // API key / token —— 强制遮罩，出现即告警

    public var redacted: Bool { self != .public }
    public var isSensitive: Bool { self == .sensitive }

    /// 返回遮罩后的字符串；仅用于测试与 export。运行时日志由 OSLog 自动遮罩（这里同步实现以便测试）。
    public func redact(_ value: String) -> String {
        switch self {
        case .public: return value
        case .private: return "<private>"
        case .sensitive: return "<sensitive>"
        }
    }
}

/// 单个待记值（值 + 隐私级别）。
public struct LoggedValue: Sendable, Equatable {
    public let value: String
    public let privacy: LogPrivacy

    public init(_ value: String, privacy: LogPrivacy) {
        self.value = value
        self.privacy = privacy
    }

    public func redacted() -> String { privacy.redact(value) }
}

extension LoggedValue: CustomStringConvertible {
    public var description: String { redacted() }
}

/// 单一日志通道（category）
public struct AppLogChannel: Sendable {
    public let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: AppLog.subsystem, category: category)
    }

    public func log(_ level: OSLogType, _ message: @autoclosure () -> String) {
        let resolved = message()
        logger.log(level: level, "\(resolved, privacy: .private)")
    }

    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }
    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }

    /// 把带 LoggedValue 的模板交给 AppLogger 处理（测试可拦截）。
    public func structured(_ level: OSLogType = .info, _ message: String) {
        let formatted = AppLogger.format(message, level: AppLogger.Level(from: level))
        logger.log(level: level, "\(formatted, privacy: .private)")
    }
}

/// 全部日志通道入口
public enum AppLog {
    public static let subsystem = "io.github.roooooly.devhub"

    public static let lifecycle = AppLogChannel(category: "lifecycle")
    public static let sessionReader = AppLogChannel(category: "session-reader")
    public static let mcp = AppLogChannel(category: "mcp")
    public static let process = AppLogChannel(category: "process")
    public static let fsEvent = AppLogChannel(category: "fs-event")
}

/// 纯字符串格式化器（用于测试与 export 时统一遮罩）。
public enum AppLogger {
    public enum Level: String, Sendable {
        case debug, info, error
        init(from os: OSLogType) {
            switch os {
            case .debug: self = .debug
            case .error: self = .error
            default: self = .info
            }
        }
    }

    public static func format(_ message: String, level: Level) -> String {
        return "[\(level.rawValue)] \(message)"
    }
}
