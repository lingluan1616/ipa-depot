import Foundation

/// 把子进程输出的字节流切成行。
/// - 以 `\n` 与 `\r` 为分隔（进度条用 `\r` 原地刷新）。
/// - 去掉 ANSI 转义序列。
/// - 空行丢弃。
/// - UTF-8 多字节字符跨块到达时会等齐再解码。
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// 追加一块数据，返回已完整的行。
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        var index = pending.startIndex
        while index < pending.endIndex {
            let byte = pending[index]
            if byte == 0x0A || byte == 0x0D {
                let slice = pending[start..<index]
                if let line = Self.decode(slice) { lines.append(line) }
                start = pending.index(after: index)
            }
            index = pending.index(after: index)
        }
        pending = Data(pending[start..<pending.endIndex])
        return lines
    }

    /// 流结束时取出残留的最后一行（没有换行结尾）。
    public mutating func flush() -> [String] {
        defer { pending = Data() }
        if let line = Self.decode(pending[...]) { return [line] }
        return []
    }

    /// 当前未成行的残留文本（用于识别不带换行的交互提示，如 `enter password: `）。
    public var pendingText: String {
        String(decoding: pending, as: UTF8.self)
    }

    private static func decode(_ slice: Data.SubSequence) -> String? {
        guard !slice.isEmpty else { return nil }
        let text = stripANSI(String(decoding: slice, as: UTF8.self))
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : text
    }

    /// 去掉 CSI / OSC 等 ANSI 转义序列。
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else {
                result.unicodeScalars.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "[":
                // CSI：参数直到 0x40–0x7E 结束
                while let c = iterator.next() {
                    if (0x40...0x7E).contains(c.value) { break }
                }
            case "]":
                // OSC：以 BEL 或 ESC \ 结束
                while let c = iterator.next() {
                    if c == "\u{07}" { break }
                    if c == "\u{1B}" { _ = iterator.next(); break }
                }
            default:
                break // 两字节序列，直接丢弃
            }
        }
        return result
    }
}
