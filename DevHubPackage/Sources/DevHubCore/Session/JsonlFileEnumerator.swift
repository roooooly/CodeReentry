import Foundation

/// 递归枚举目录下的 `*.jsonl` 文件（异步流形式，适合大目录）。
///
/// 统一 Claude/Codex 的 Session reader 与 Usage reader 的文件遍历逻辑，
/// 消除各 reader 各自重写的 `walkJsonl`。Claude 的 projects 树含 `subagents/`
/// 子目录需要跳过，Codex 的 sessions 树不需要——由 `skipSubagents` 控制。
public enum JsonlFileEnumerator {

    /// 异步枚举 `root` 下所有 `.jsonl` 文件。
    /// - Parameters:
    ///   - root: 要遍历的根目录（不存在时返回空流）。
    ///   - skipSubagents: 为 true 时跳过名为 `subagents` 的目录及其内容（Claude 适用）。
    public static func enumerate(in root: URL, skipSubagents: Bool = false) -> AsyncStream<URL> {
        AsyncStream { continuation in
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continuation.finish(); return
            }
            for case let url as URL in enumerator {
                if skipSubagents, url.lastPathComponent == "subagents" {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension == "jsonl" {
                    if skipSubagents, url.path.contains("/subagents/") { continue }
                    continuation.yield(url)
                }
            }
            continuation.finish()
        }
    }
}
/// 高性能逐行遍历（§JSONL 解析）。
///
/// Swift 的 `String.split(separator: "\n")` / `enumerateLines` 对大文件逐行处理时，
/// 每行都要做 grapheme cluster 处理或 NSString 桥接，6.5 万行的单文件即可让 CPU
/// 满载数秒；配合逐行 `contains`（NSString 本地化搜索）更慢。这里提供基于
/// UTF-8 字节扫描的实现，对大 JSONL 快一个数量级（实测 6.5 万行：字节扫描 0.58s
/// vs enumerateLines+contains 7.3s）。
public enum LineSplitter {

    /// 把文本按行拆成数组（跳过空行）。用于会话正文查看等单文件、数据量可控的场景。
    /// 用量扫描等大文件场景改用 `lines(containing:in:)` 的字节级预过滤。
    public static func nonEmptyLines(_ content: String) -> [String] {
        var lines: [String] = []
        content.enumerateLines { line, _ in
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// 返回所有包含 `needle` 的非空行（字节级匹配，跳过本地化搜索开销）。
    /// 用于 JSONL 用量解析：184 万行里只有几千行命中，先廉价过滤再 JSON 解析。
    /// 返回 `Data`（每行一份）而非 `String`，因为命中行通常直接喂给 `JSONSerialization`，
    /// 避免字节→String→Data 的双重转换。
    ///
    /// 实现：直接在 String 的 UTF-8 内存上用裸指针扫描，零拷贝、零逐字节映射
    /// （早期版本曾用 `utf8CString + map { UInt8(bitPattern:) }` 逐字节转换整文件，
    /// 对几 MB 的单文件即成为瓶颈）。
    public static func lines(containing needle: String, in content: String) -> [Data] {
        guard !needle.isEmpty else { return [] }
        let needleBytes: [UInt8] = Array(needle.utf8)
        let needleCount = needleBytes.count
        let nl: UInt8 = 0x0A

        var matched: [Data] = []
        // 两段裸指针访问：content 的 UTF-8 内存 + needle 的字节内存，
        // 消除内层循环里的 Array 下标边界/类型检查（曾导致 184 万行满载数分钟）。
        var content = content
        needleBytes.withUnsafeBufferPointer { (nbuf: UnsafeBufferPointer<UInt8>) in
            guard let needleBase = nbuf.baseAddress, needleCount > 0 else { return }
            content.withUTF8 { (body: UnsafeBufferPointer<UInt8>) in
                guard let base = body.baseAddress else { return }
                let total = body.count
                var lineStart = 0
                var i = 0
                while i < total {
                    if base[i] == nl {
                        let len = i - lineStart
                        if len >= needleCount {
                            let limit = i - needleCount
                            var j = lineStart
                            var found = false
                            while j <= limit {
                                // memcmp 风格比较，指针直接寻址，无 Array 检查开销。
                                var k = 0
                                while k < needleCount && base[j + k] == needleBase[k] { k += 1 }
                                if k == needleCount { found = true; break }
                                j += 1
                            }
                            if found {
                                matched.append(Data(bytes: base + lineStart, count: len))
                            }
                        }
                        lineStart = i + 1
                    }
                    i += 1
                }
                // 末行（无尾换行）
                let len = total - lineStart
                if len >= needleCount {
                    let limit = total - needleCount
                    var j = lineStart
                    var found = false
                    while j <= limit {
                        var k = 0
                        while k < needleCount && base[j + k] == needleBase[k] { k += 1 }
                        if k == needleCount { found = true; break }
                        j += 1
                    }
                    if found {
                        matched.append(Data(bytes: base + lineStart, count: len))
                    }
                }
            }
        }
        return matched
    }
}
