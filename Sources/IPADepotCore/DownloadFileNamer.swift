import Foundation

/// 下载文件命名：`<name>_<version>.ipa`，替换非法字符；同名已存在（或已被队列占用、或有 `.tmp` 残留）时加序号。
public enum DownloadFileNamer {
    /// Finder / HFS+ / APFS 与常见同步工具不友好的字符。
    static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)

    public static func sanitize(_ text: String, fallback: String = "app") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(illegal.contains(scalar) ? "_" : scalar)
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉开头的点（避免隐藏文件），压缩连续下划线
        while result.hasPrefix(".") { result.removeFirst() }
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " _"))
        if result.isEmpty { result = fallback }
        // 文件名长度上限 255 字节，留出版本号与序号空间
        while result.utf8.count > 160 { result.removeLast() }
        return result
    }

    public static func baseName(name: String, version: String) -> String {
        let v = sanitize(version, fallback: "")
        let n = sanitize(name)
        return v.isEmpty ? n : "\(n)_\(v)"
    }

    /// 在目录中找一个可用的目标文件 URL。
    public static func uniqueURL(in directory: URL, name: String, version: String,
                                 reserved: Set<String> = [],
                                 fileManager: FileManager = .default) -> URL {
        let base = baseName(name: name, version: version)
        var index = 1
        while true {
            let fileName = index == 1 ? "\(base).ipa" : "\(base) (\(index)).ipa"
            let url = directory.appendingPathComponent(fileName)
            let taken = reserved.contains(url.standardizedFileURL.path)
                || fileManager.fileExists(atPath: url.path)
                || fileManager.fileExists(atPath: url.path + ".tmp")
            if !taken { return url }
            index += 1
        }
    }
}
