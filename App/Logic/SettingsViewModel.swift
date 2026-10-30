import Foundation
import Observation
import IPADepotCore

@MainActor
@Observable
final class SettingsViewModel {
    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(ReleaseInfo)
        case failed(ErrorPresentation)
    }

    static let downloadDirectoryKey = "downloadDirectory"
    /// 同时下载数（1 / 2 / 3，默认 1）。
    static let maxConcurrentDownloadsKey = "maxConcurrentDownloads"
    static let maxConcurrentDownloadsOptions = Array(DownloadQueue.concurrencyRange)

    private(set) var downloadDirectory: URL
    private(set) var versionsCacheSize: Int64 = 0
    private(set) var artworkCacheSize: Int64 = 0
    private(set) var isClearingCache = false
    private(set) var ipatoolVersion: String?
    private(set) var ipatoolVersionError: String?
    private(set) var updateState: UpdateState = .idle
    /// 同时下载数（1...3）。改动即时生效：调小时不打断正在运行的任务，只是不再补位。
    private(set) var maxConcurrentDownloads: Int

    let appVersion: String
    let owner: String?

    @ObservationIgnored var onCacheCleared: (() -> Void)?
    /// 同时下载数变化时调用（AppModel 接到下载队列的 `setMaxConcurrent`）。
    @ObservationIgnored var onMaxConcurrentDownloadsChanged: ((Int) -> Void)?
    @ObservationIgnored private let defaults: KeyValueStoring
    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let ipatoolVersionProvider: @Sendable () async throws -> String
    @ObservationIgnored private let makeUpdateChecker: @Sendable (String) -> UpdateChecking

    init(defaults: KeyValueStoring,
         paths: AppPaths,
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         owner: String? = ProjectInfo.owner,
         ipatoolVersion: @escaping @Sendable () async throws -> String,
         makeUpdateChecker: @escaping @Sendable (String) -> UpdateChecking) {
        self.defaults = defaults
        self.paths = paths
        self.appVersion = appVersion
        self.owner = owner
        self.ipatoolVersionProvider = ipatoolVersion
        self.makeUpdateChecker = makeUpdateChecker
        if let saved = defaults.string(forKey: Self.downloadDirectoryKey), !saved.isEmpty {
            downloadDirectory = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            downloadDirectory = Self.defaultDownloadDirectory
        }
        maxConcurrentDownloads = Self.clampConcurrency(defaults.integer(forKey: Self.maxConcurrentDownloadsKey))
    }

    /// 钳到 1...3；未设置（0）或异常值按默认 1 处理（超过 3 按 3）。
    static func clampConcurrency(_ value: Int) -> Int {
        let range = DownloadQueue.concurrencyRange
        return value < range.lowerBound ? range.lowerBound : min(value, range.upperBound)
    }

    // MARK: - 同时下载数

    func setMaxConcurrentDownloads(_ value: Int) {
        let clamped = Self.clampConcurrency(value)
        guard clamped != maxConcurrentDownloads else { return }
        maxConcurrentDownloads = clamped
        defaults.set(clamped, forKey: Self.maxConcurrentDownloadsKey)
        onMaxConcurrentDownloadsChanged?(clamped)
    }

    /// 默认 `~/Downloads/IPA Depot`。
    static var defaultDownloadDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        return downloads.appendingPathComponent("IPA Depot", isDirectory: true)
    }

    // MARK: - 下载目录

    func setDownloadDirectory(_ url: URL) {
        downloadDirectory = url.standardizedFileURL
        defaults.set(downloadDirectory.path, forKey: Self.downloadDirectoryKey)
    }

    func resetDownloadDirectory() {
        downloadDirectory = Self.defaultDownloadDirectory
        defaults.set(nil, forKey: Self.downloadDirectoryKey)
    }

    /// 返回下载目录，不存在时创建（在真正下载时才调用，不在启动时创建）。
    func ensureDownloadDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        return downloadDirectory
    }

    // MARK: - 缓存（只动本 App 的 cache 目录，不碰 ~/Library/Caches/ipatool）

    func refreshCacheSizes() async {
        let versionsDir = paths.versionsCacheDirectory
        let artworkDir = paths.artworkCacheDirectory
        let sizes = await Task.detached {
            (DirectoryUsage.size(of: versionsDir), DirectoryUsage.size(of: artworkDir))
        }.value
        versionsCacheSize = sizes.0
        artworkCacheSize = sizes.1
    }

    var totalCacheSize: Int64 { versionsCacheSize + artworkCacheSize }

    func clearCache() async {
        isClearingCache = true
        let dirs = [paths.versionsCacheDirectory, paths.artworkCacheDirectory]
        await Task.detached {
            for dir in dirs { try? DirectoryUsage.removeContents(of: dir) }
        }.value
        isClearingCache = false
        onCacheCleared?()
        await refreshCacheSizes()
    }

    // MARK: - 关于

    func loadIpatoolVersion() async {
        guard ipatoolVersion == nil else { return }
        do {
            ipatoolVersion = try await ipatoolVersionProvider()
            ipatoolVersionError = nil
        } catch let error as IpatoolError {
            ipatoolVersionError = error.message
        } catch {
            ipatoolVersionError = error.localizedDescription
        }
    }

    /// 关于页「许可」里的三项：App 自身、ipatool、字体。
    enum License: String, Identifiable, CaseIterable {
        case app, ipatool, font
        var id: String { rawValue }

        /// 在 `Contents/Resources` 下的相对路径。
        var resourcePath: String {
            switch self {
            case .app: return "LICENSE"
            case .ipatool: return "ipatool-LICENSE"
            case .font: return "Fonts/阿里妈妈数黑体-许可.txt"
            }
        }
    }

    /// 许可全文（随 App 打包在 `Contents/Resources`）。
    func licenseText(_ license: License, bundle: Bundle = .main) -> String? {
        guard let base = bundle.resourceURL else { return nil }
        return try? String(contentsOf: base.appendingPathComponent(license.resourcePath), encoding: .utf8)
    }

    /// `Contents/Resources/ipatool-LICENSE` 全文。
    func ipatoolLicenseText(bundle: Bundle = .main) -> String? {
        licenseText(.ipatool, bundle: bundle)
    }

    // MARK: - 检查更新

    var canCheckForUpdates: Bool { owner != nil && updateState != .checking }

    func checkForUpdates() async {
        guard let owner else { return }
        updateState = .checking
        do {
            switch try await makeUpdateChecker(owner).check(currentVersion: appVersion) {
            case .upToDate(let latest): updateState = .upToDate(latest)
            case .updateAvailable(let release): updateState = .available(release)
            }
        } catch let error as IpatoolError {
            updateState = .failed(ErrorPresentation(error))
        } catch {
            updateState = .failed(ErrorPresentation(message: error.localizedDescription))
        }
    }
}
