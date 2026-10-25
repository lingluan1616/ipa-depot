import Foundation

/// 下载进度。
public struct DownloadProgress: Sendable, Equatable {
    public enum Source: String, Sendable { case progressBar, tempFile }

    /// 0...1；总大小未知时为 nil。
    public let fraction: Double?
    public let bytes: Int64
    public let total: Int64?
    /// 字节/秒；未知时为 nil。
    public let bytesPerSecond: Double?
    public let source: Source

    public init(fraction: Double?, bytes: Int64, total: Int64?, bytesPerSecond: Double?, source: Source) {
        self.fraction = fraction
        self.bytes = bytes
        self.total = total
        self.bytesPerSecond = bytesPerSecond
        self.source = source
    }
}

/// 解析 ipatool（schollz/progressbar）的进度条文本，例如
/// `downloading  21% |████      | (12/45 MB, 1.2 MB/s)`。单位为 1000 进制（`KiB` 等则按 1024）。
public enum ProgressParser {
    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#)
    private static let countRegex = try! NSRegularExpression(
        pattern: #"\(\s*(\d+(?:\.\d+)?)\s*([kKMGTP]?i?B)?\s*/\s*(\d+(?:\.\d+)?)\s*([kKMGTP]?i?B)"#)
    private static let speedRegex = try! NSRegularExpression(
        pattern: #"(\d+(?:\.\d+)?)\s*([kKMGTP]?i?B)\s*/\s*s"#)

    public static func parse(_ line: String) -> DownloadProgress? {
        let text = LineBuffer.stripANSI(line)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        var percent: Double?
        if let m = percentRegex.firstMatch(in: text, range: full) {
            percent = Double(ns.substring(with: m.range(at: 1)))
        }

        var bytes: Int64?
        var total: Int64?
        if let m = countRegex.firstMatch(in: text, range: full) {
            let totalUnit = ns.substring(with: m.range(at: 4))
            let currentUnit = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : totalUnit
            if let current = Double(ns.substring(with: m.range(at: 1))),
               let max = Double(ns.substring(with: m.range(at: 3))) {
                bytes = Int64((current * multiplier(currentUnit)).rounded())
                total = Int64((max * multiplier(totalUnit)).rounded())
            }
        }

        var speed: Double?
        // 速度只在括号内逗号之后找，避免把 "12/45 MB" 误当速度
        if let paren = text.range(of: "("), let comma = text.range(of: ",", range: paren.upperBound..<text.endIndex) {
            let tail = String(text[comma.upperBound...])
            let tns = tail as NSString
            if let m = speedRegex.firstMatch(in: tail, range: NSRange(location: 0, length: tns.length)),
               let value = Double(tns.substring(with: m.range(at: 1))) {
                speed = value * multiplier(tns.substring(with: m.range(at: 2)))
            }
        }

        guard percent != nil || bytes != nil else { return nil }

        var fraction: Double?
        if let percent {
            fraction = min(max(percent / 100, 0), 1)
        } else if let bytes, let total, total > 0 {
            fraction = min(max(Double(bytes) / Double(total), 0), 1)
        }
        if let t = total, t <= 0 { total = nil }

        return DownloadProgress(fraction: fraction,
                                bytes: bytes ?? 0,
                                total: total,
                                bytesPerSecond: speed,
                                source: .progressBar)
    }

    static func multiplier(_ unit: String) -> Double {
        let u = unit.uppercased()
        let binary = u.contains("I")
        let base: Double = binary ? 1024 : 1000
        switch u.first {
        case "K": return base
        case "M": return base * base
        case "G": return pow(base, 3)
        case "T": return pow(base, 4)
        case "P": return pow(base, 5)
        default: return 1
        }
    }
}
