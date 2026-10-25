import Foundation
import IPADepotCore

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let text = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file)
        return "\(text)/s"
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 价格：0 → 免费，否则 ¥xx（最多两位小数）。
    static func price(_ price: Double) -> String {
        if price == 0 { return String(localized: "免费") }
        let number = price.formatted(.number.precision(.fractionLength(0...2)))
        return "¥\(number)"
    }

    /// ipatool 平台值 → 显示标签。
    static func platformLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "iphone", "ios": return "iPhone"
        case "ipad", "ipados": return "iPad"
        case "macos", "mac", "osx": return "Mac"
        case "watchos", "watch": return "Watch"
        case "appletv", "appletvos", "tvos": return "TV"
        case "visionos", "vision": return "Vision"
        default: return raw
        }
    }
}

/// 错误的界面呈现：中文文案（`IpatoolError.message`）+ 原始错误（折叠显示）。
struct ErrorPresentation: Equatable, Identifiable {
    var id: String { message + raw }
    let message: String
    let raw: String

    init(_ error: IpatoolError) {
        message = error.message
        raw = error.raw
    }

    init(message: String, raw: String = "") {
        self.message = message
        self.raw = raw
    }
}
