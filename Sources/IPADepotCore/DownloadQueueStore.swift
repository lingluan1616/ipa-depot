import Foundation

/// 跨启动保存的一条下载任务（排队中 / 已暂停 / 失败 / 退出时仍在进行的任务，恢复时一律为「已暂停」）。
public struct PersistedDownload: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var appID: Int64
    /// 显示名称（文件名也由它生成）。
    public var name: String
    public var bundleID: String
    /// 显示与文件名用的版本号（未知时为外部版本 ID）。
    public var versionLabel: String
    /// nil = 最新版。
    public var externalVersionID: String?
    /// 是否以 `--purchase` 下载（领取免费许可）。
    public var purchase: Bool
    /// 目标文件绝对路径（`.ipa`）；续传依靠同目录下的 `<目标>.tmp`。
    public var outputPath: String
    /// 传给 ipatool `--platform` 的值（iPhone 为 nil）。
    public var platform: String?
    /// 界面上的平台（iphone / ipad / mac）。
    public var displayPlatform: String
    public var isFree: Bool
    /// 已知的安装包总大小（字节）；未知为 nil。
    public var totalBytes: Int64?
    public var addedAt: Date
    /// 上次失败的原因（没有失败为 nil）；恢复后仍显示，重试时清除。旧文件没有此字段时为 nil。
    public var failure: PersistedFailure?
    /// 任务所属账号；0.1.0 的旧文件没有此字段（nil），视为当前账号。
    public var accountID: UUID?
    /// 从公开目录（浏览地区）发起的任务：所浏览的国家代码；其他任务为 nil。旧文件没有此字段。
    public var catalogCountry: String?

    public init(id: UUID, appID: Int64, name: String, bundleID: String, versionLabel: String,
                externalVersionID: String?, purchase: Bool, outputPath: String, platform: String?,
                displayPlatform: String, isFree: Bool, totalBytes: Int64?, addedAt: Date,
                failure: PersistedFailure? = nil, accountID: UUID? = nil, catalogCountry: String? = nil) {
        self.id = id
        self.appID = appID
        self.name = name
        self.bundleID = bundleID
        self.versionLabel = versionLabel
        self.externalVersionID = externalVersionID
        self.purchase = purchase
        self.outputPath = outputPath
        self.platform = platform
        self.displayPlatform = displayPlatform
        self.isFree = isFree
        self.totalBytes = totalBytes
        self.addedAt = addedAt
        self.failure = failure
        self.accountID = accountID
        self.catalogCountry = catalogCountry
    }

    /// 重新下载用的请求（与当初入队时同参数）。
    public var request: DownloadRequest {
        DownloadRequest(appID: appID, externalVersionID: externalVersionID, purchase: purchase,
                        output: URL(fileURLWithPath: outputPath), platform: platform, accountID: accountID)
    }

    /// 恢复时展示的进度：`.tmp` 当前大小 + 已知总大小。两者都没有时为 nil。
    public func restoredProgress() -> DownloadProgress? {
        let bytes = DownloadTask.tempFileSize(for: request)
        guard bytes != nil || totalBytes != nil else { return nil }
        let size = bytes ?? 0
        let fraction = totalBytes.flatMap { $0 > 0 ? min(Double(size) / Double($0), 1) : nil }
        return DownloadProgress(fraction: fraction, bytes: size, total: totalBytes, bytesPerSecond: nil, source: .tempFile)
    }
}

/// 保存下来的失败原因：中文文案 `message`（写入时的文本，便于直接阅读文件）+ 类别与 ipatool 原始英文（恢复「查看原始错误」用）。
public struct PersistedFailure: Sendable, Codable, Equatable {
    /// `IpatoolErrorKind` 的原始值；以字符串保存，未来出现未知类别时按 `.unknown` 处理而不是整份文件解析失败。
    public var kind: String
    public var message: String
    public var raw: String

    public init(kind: String, message: String, raw: String) {
        self.kind = kind
        self.message = message
        self.raw = raw
    }

    public init(_ error: IpatoolError) {
        self.init(kind: error.kind.rawValue, message: error.message, raw: error.raw)
    }

    public var error: IpatoolError {
        IpatoolError(kind: IpatoolErrorKind(rawValue: kind) ?? .unknown, raw: raw)
    }
}

/// `queue.json` 读写：`{"version":1,"items":[…]}`，原子写；文件缺失或损坏时视为空队列。
public struct DownloadQueueStore: Sendable {
    public static let formatVersion = 1

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Envelope: Codable {
        var version: Int
        var items: [PersistedDownload]
    }

    public func load() -> [PersistedDownload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.version <= Self.formatVersion else { return [] }
        return envelope.items
    }

    public func save(_ items: [PersistedDownload]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.formatVersion, items: items))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
