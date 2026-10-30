import Foundation

/// 0.1.0 升级迁移时，给 `history.json` 与 `queue.json` 里没有账号归属（`accountID == nil`）的条目统一盖上迁移账号的 id。
/// 只改缺失的条目，已有归属的不动，所以重复执行不会产生变化（幂等）；没有需要改的条目时不重写文件。
public enum LegacyAccountStamp {
    public struct Result: Sendable, Equatable {
        public var history: Int
        public var queue: Int
        public init(history: Int, queue: Int) {
            self.history = history
            self.queue = queue
        }
    }

    /// - Parameters:
    ///   - regionLabel: 写进下载记录的地区快照（`AccountRegion` 原始值）；nil = 不写。
    @discardableResult
    public static func stamp(accountID: UUID, regionLabel: String? = nil,
                             history: HistoryStore, queue: DownloadQueueStore) throws -> Result {
        var result = Result(history: 0, queue: 0)

        var records = history.load()
        for index in records.indices where records[index].accountID == nil {
            records[index].accountID = accountID
            if records[index].regionLabel == nil { records[index].regionLabel = regionLabel }
            result.history += 1
        }
        if result.history > 0 { try history.save(records) }

        var items = queue.load()
        for index in items.indices where items[index].accountID == nil {
            items[index].accountID = accountID
            result.queue += 1
        }
        if result.queue > 0 { try queue.save(items) }
        return result
    }
}
