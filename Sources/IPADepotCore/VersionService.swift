import Foundation

/// 历史版本：`list-versions` 取 ID 列表，`get-version-metadata` 逐个取版本号与日期（并发上限 3，磁盘缓存）。
/// 账号没有授权时 ipatool 报 `license is required`，这里抛 `IpatoolError(kind: .licenseRequired)`。
public struct VersionService: Sendable {
    public let runner: IpatoolRunner
    public let cache: VersionCache
    public let maxConcurrency: Int

    public init(runner: IpatoolRunner, cache: VersionCache? = nil, maxConcurrency: Int = 3) {
        self.runner = runner
        self.cache = cache ?? VersionCache(directory: runner.paths.versionsCacheDirectory)
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// 取外部版本 ID 列表，并写入缓存（保留已有元数据）。
    public func listVersionIDs(appID: Int64, platform: String? = nil) async throws -> [String] {
        var args = ["list-versions", "-i", String(appID)]
        if let platform { args += ["--platform", platform] }
        let result = try await runner.run(args)
        let (ids, bundleID) = try Self.parseVersionList(result)
        var entry = cache.load(appID: appID) ?? CachedVersions(appID: appID)
        entry.versionIDs = ids
        entry.bundleID = bundleID ?? entry.bundleID
        entry.updatedAt = Date()
        try? cache.save(entry)
        return ids
    }

    /// 单个版本的元数据（命中缓存直接返回）。
    public func metadata(appID: Int64, versionID: String, useCache: Bool = true) async throws -> VersionMetadata {
        if useCache, let cached = cache.load(appID: appID)?.metadata[versionID] { return cached }
        let result = try await runner.run(["get-version-metadata", "-i", String(appID),
                                           "--external-version-id", versionID])
        let meta = try Self.parseMetadata(result, fallbackID: versionID)
        var entry = cache.load(appID: appID) ?? CachedVersions(appID: appID)
        entry.metadata[versionID] = meta
        try? cache.save(entry)
        return meta
    }

    /// 批量取元数据，并发不超过 `maxConcurrency`；每取到一个就回调一次（便于界面懒加载刷新）。
    /// 返回顺序与 `versionIDs` 一致；单个失败不会中断整体，失败项不在结果中（`.licenseRequired` / 取消除外，会直接抛出）。
    public func metadata(appID: Int64, versionIDs: [String], useCache: Bool = true,
                         onEach: (@Sendable (VersionMetadata) -> Void)? = nil) async throws -> [VersionMetadata] {
        let cached = useCache ? (cache.load(appID: appID)?.metadata ?? [:]) : [:]
        var results: [String: VersionMetadata] = [:]
        var pending: [String] = []
        for id in versionIDs {
            if let hit = cached[id] { results[id] = hit; onEach?(hit) } else { pending.append(id) }
        }

        let fetched: [String: VersionMetadata] = try await withThrowingTaskGroup(of: (String, VersionMetadata?).self) { group in
            var collected: [String: VersionMetadata] = [:]
            var iterator = pending.makeIterator()
            let runner = self.runner
            func addNext() -> Bool {
                guard let id = iterator.next() else { return false }
                group.addTask {
                    do {
                        let result = try await runner.run(["get-version-metadata", "-i", String(appID),
                                                           "--external-version-id", id])
                        return (id, try Self.parseMetadata(result, fallbackID: id))
                    } catch let error as IpatoolError where error.kind == .licenseRequired || error.kind == .cancelled
                                || error.kind == .notLoggedIn || error.kind == .passwordTokenExpired {
                        throw error
                    } catch {
                        return (id, nil)
                    }
                }
                return true
            }
            for _ in 0..<maxConcurrency where addNext() {}
            while let (id, meta) = try await group.next() {
                if let meta { collected[id] = meta; onEach?(meta) }
                _ = addNext()
            }
            return collected
        }

        results.merge(fetched) { _, new in new }
        if !fetched.isEmpty {
            var entry = cache.load(appID: appID) ?? CachedVersions(appID: appID)
            entry.metadata.merge(fetched) { _, new in new }
            entry.updatedAt = Date()
            try? cache.save(entry)
        }
        return versionIDs.compactMap { results[$0] }
    }

    // MARK: - 解析

    public static func parseVersionList(_ result: IpatoolProcess.Result) throws -> ([String], String?) {
        guard let event = result.lastEvent(containing: "externalVersionIdentifiers") else {
            throw IpatoolError(kind: .invalidOutput, raw: result.textLines.joined(separator: "\n"))
        }
        guard case .array(let values)? = event["externalVersionIdentifiers"] else {
            throw IpatoolError(kind: .invalidOutput, raw: String(decoding: event.rawData, as: UTF8.self))
        }
        let ids = values.compactMap { value -> String? in
            switch value {
            case .string(let s): return s
            case .number(let n): return String(Int64(n))
            default: return nil
            }
        }
        // 用 -i 调用时 ipatool 2.7.0 返回的 bundleID 是空字符串（真机实测），视为未知
        let bundleID = event["bundleID"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return (ids, bundleID)
    }

    public static func parseMetadata(_ result: IpatoolProcess.Result, fallbackID: String) throws -> VersionMetadata {
        guard let event = result.lastEvent(containing: "displayVersion") else {
            throw IpatoolError(kind: .invalidOutput, raw: result.textLines.joined(separator: "\n"))
        }
        let id: String
        switch event["externalVersionID"] {
        case .string(let s)?: id = s
        case .number(let n)?: id = String(Int64(n))
        default: id = fallbackID
        }
        return VersionMetadata(externalVersionID: id,
                               displayVersion: event["displayVersion"]?.stringValue ?? "",
                               releaseDate: event["releaseDate"]?.stringValue.flatMap(parseDate))
    }

    static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}
