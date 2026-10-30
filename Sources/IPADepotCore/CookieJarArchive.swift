import Foundation

/// 每个账号独立保存 ipatool 的 Cookie 文件。
///
/// ipatool v2.7.0 的行为（源码核实，见 docs/progress-phase5.md）：
/// - 状态目录：`XDG_STATE_HOME/ipatool`；但只要 `~/.ipatool` 存在就用旧目录（新目录不存在时它会把旧目录整体改名迁移过去）。
///   所以「`~/.ipatool` 存在 → 用它，否则 `XDG_STATE_HOME/ipatool`」与 ipatool 下一次运行时实际使用的目录一致。
/// - Cookie 文件名 `cookies`（juju/persistent-cookiejar 的 JSON 数组）。每次 HTTP 请求后 `Save()` 会**合并**磁盘上已有的
///   Cookie 再整体写回；`auth revoke` 不碰 Cookie 文件。因此登录另一个账号前必须先把 Cookie 文件换成目标账号的
///   （没有就清空），否则旧账号的 Cookie 会被合并进新会话。
public struct CookieJarArchive: Sendable {
    public static let cookieFileName = "cookies"
    public static let legacyDirectoryName = ".ipatool"

    /// 用户主目录（ipatool 用它找 `~/.ipatool`）。
    public let homeDirectory: URL
    /// 传给 ipatool 的 `XDG_STATE_HOME`。
    public let stateHome: URL
    /// 本 App 保存各账号 Cookie 的根目录（`App Support/accounts`）。
    public let archiveRoot: URL

    public init(homeDirectory: URL, stateHome: URL, archiveRoot: URL) {
        self.homeDirectory = homeDirectory
        self.stateHome = stateHome
        self.archiveRoot = archiveRoot
    }

    public init(paths: AppPaths, homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.init(homeDirectory: homeDirectory, stateHome: paths.stateDirectory, archiveRoot: paths.accountsDirectory)
    }

    /// ipatool 实际使用的状态目录。
    public var ipatoolStateDirectory: URL {
        let legacy = homeDirectory.appendingPathComponent(Self.legacyDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return legacy
        }
        return stateHome.appendingPathComponent("ipatool", isDirectory: true)
    }

    /// ipatool 当前读写的 Cookie 文件。
    public var liveCookiesFile: URL { ipatoolStateDirectory.appendingPathComponent(Self.cookieFileName) }

    public func archiveDirectory(for accountID: UUID) -> URL {
        archiveRoot.appendingPathComponent(accountID.uuidString, isDirectory: true)
    }

    public func archiveFile(for accountID: UUID) -> URL {
        archiveDirectory(for: accountID).appendingPathComponent(Self.cookieFileName)
    }

    public func hasArchive(for accountID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: archiveFile(for: accountID).path)
    }

    /// 把当前 Cookie 文件存为该账号的 Cookie。当前没有 Cookie 文件时什么都不做（保留已存的）。
    public func save(accountID: UUID) throws {
        let live = liveCookiesFile
        guard FileManager.default.fileExists(atPath: live.path) else { return }
        try Self.atomicCopy(from: live, to: archiveFile(for: accountID))
    }

    /// 换入该账号的 Cookie；该账号没有保存过 Cookie 时清空当前 Cookie 文件（以免串号）。
    public func restore(accountID: UUID) throws {
        let archive = archiveFile(for: accountID)
        if FileManager.default.fileExists(atPath: archive.path) {
            try Self.atomicCopy(from: archive, to: liveCookiesFile)
        } else {
            try clearLive()
        }
    }

    /// 清空当前 Cookie 文件（删除；ipatool 下次请求时会重新创建）。
    public func clearLive() throws {
        let live = liveCookiesFile
        do {
            try FileManager.default.removeItem(at: live)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return
        }
    }

    /// 删除该账号保存的 Cookie。
    public func removeArchive(accountID: UUID) {
        try? FileManager.default.removeItem(at: archiveDirectory(for: accountID))
    }

    /// 原子拷贝：先写同目录临时文件（权限 0600），再 `rename` 覆盖目标。
    static func atomicCopy(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        if rename(temporary.path, destination.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}
