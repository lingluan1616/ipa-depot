import Foundation

/// 下载任务的抽象（便于测试替身）。`DownloadTask` 实现它。
/// 约定：`start` 可在暂停/失败后再次调用（继续）；`pause` / `cancel` 让正在进行的 `start` 尽快返回对应结果。
public protocol DownloadTasking: AnyObject, Sendable {
    var request: DownloadRequest { get }
    func start(onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome
    func pause()
    func cancel()
}

extension DownloadTask: DownloadTasking {}

/// 队列中一项的状态。
public enum DownloadItemStatus: Sendable, Equatable {
    /// 等待前面的任务完成。
    case queued
    case running
    /// 已请求暂停/取消，正在等子进程退出。
    case stopping
    case paused
    case verifying
    case completed(DownloadResult)
    case failed(IpatoolError)

    public var isActive: Bool {
        switch self {
        case .running, .stopping, .verifying: return true
        default: return false
        }
    }

    public var isFinished: Bool {
        if case .completed = self { return true }
        return false
    }
}

/// 队列中的一项（对外发布的快照）。
public struct DownloadQueueItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: DownloadRequest
    public internal(set) var status: DownloadItemStatus
    public internal(set) var progress: DownloadProgress?
    /// 最近一条非进度日志（如「首次准备组件」）。
    public internal(set) var lastLog: String?
    public let addedAt: Date

    public init(id: UUID, request: DownloadRequest, status: DownloadItemStatus = .queued,
                progress: DownloadProgress? = nil, lastLog: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.request = request
        self.status = status
        self.progress = progress
        self.lastLog = lastLog
        self.addedAt = addedAt
    }
}

/// 下载队列：同一时刻只运行一个任务，其余排队。
///
/// - `add`：入队（排在末尾），空闲时立即开始；
/// - `pause`：运行中 → 终止子进程，变为 `.paused`；排队中 → 直接 `.paused`（跳过）；
/// - `resume`：`.paused` / `.failed` → 重新排队（ipatool 依靠 `.tmp` 续传）；
/// - `cancel`：停止并**从队列移除**，同时删除 `<目标>.tmp` 残留；
/// - `remove`：移除已完成 / 失败 / 暂停的条目（运行中的请用 `cancel`）；
/// - `updates()`：订阅快照流，订阅时立即收到当前快照。
public actor DownloadQueue {
    public typealias TaskFactory = @Sendable (DownloadRequest) -> DownloadTasking

    private struct Entry {
        var item: DownloadQueueItem
        let task: DownloadTasking
        var cancelRequested = false
    }

    private let makeTask: TaskFactory
    private var entries: [Entry] = []
    private var runningID: UUID?
    private var subscribers: [UUID: AsyncStream<[DownloadQueueItem]>.Continuation] = [:]

    public init(makeTask: @escaping TaskFactory) {
        self.makeTask = makeTask
    }

    public init(runner: IpatoolRunner) {
        self.makeTask = { DownloadTask(request: $0, runner: runner) }
    }

    // MARK: - 查询

    public var items: [DownloadQueueItem] { entries.map(\.item) }

    public func item(_ id: UUID) -> DownloadQueueItem? { entries.first { $0.item.id == id }?.item }

    /// 正在运行（含停止中 / 校验中）的条目。
    public var activeItemID: UUID? { runningID }

    /// 订阅快照。流在订阅时先发当前快照，之后每次变化发一次。
    public func updates() -> AsyncStream<[DownloadQueueItem]> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<[DownloadQueueItem]>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(key) }
        }
        subscribers[key] = continuation
        continuation.yield(items)
        return stream
    }

    private func unsubscribe(_ key: UUID) { subscribers[key] = nil }

    // MARK: - 操作

    @discardableResult
    public func add(_ request: DownloadRequest, id: UUID = UUID()) -> UUID {
        entries.append(Entry(item: DownloadQueueItem(id: id, request: request), task: makeTask(request)))
        publish()
        pump()
        return id
    }

    public func pause(_ id: UUID) {
        guard let index = index(of: id) else { return }
        switch entries[index].item.status {
        case .running, .verifying:
            entries[index].item.status = .stopping
            entries[index].task.pause()
            publish()
        case .queued:
            entries[index].item.status = .paused
            publish()
        default:
            break
        }
    }

    public func resume(_ id: UUID) {
        guard let index = index(of: id) else { return }
        switch entries[index].item.status {
        case .paused, .failed:
            entries[index].item.status = .queued
            entries[index].item.lastLog = nil
            publish()
            pump()
        default:
            break
        }
    }

    public func cancel(_ id: UUID) {
        guard let index = index(of: id) else { return }
        if runningID == id {
            entries[index].cancelRequested = true
            entries[index].item.status = .stopping
            entries[index].task.cancel()
            publish()
        } else if !entries[index].item.status.isFinished {
            let request = entries[index].item.request
            entries.remove(at: index)
            Self.removeTemporaryFile(for: request)
            publish()
        }
    }

    public func remove(_ id: UUID) {
        guard runningID != id, let index = index(of: id) else { return }
        entries.remove(at: index)
        publish()
    }

    /// 移除所有已完成条目。
    public func removeCompleted() {
        entries.removeAll { $0.item.status.isFinished }
        publish()
    }

    // MARK: - 内部

    private func index(of id: UUID) -> Int? { entries.firstIndex { $0.item.id == id } }

    private func publish() {
        let snapshot = items
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    /// 空闲时启动下一个排队项。
    private func pump() {
        guard runningID == nil, let index = entries.firstIndex(where: { $0.item.status == .queued }) else { return }
        let id = entries[index].item.id
        let task = entries[index].task
        runningID = id
        entries[index].item.status = .running
        publish()

        // 事件与最终结果经由同一个有序流回到 actor，保证处理顺序与 DownloadTask 发出的一致。
        let (messages, continuation) = AsyncStream<Message>.makeStream()
        Task { [weak self] in
            for await message in messages {
                switch message {
                case .event(let event): await self?.handle(event, for: id)
                case .outcome(let outcome): await self?.finish(id, outcome: outcome)
                }
            }
        }
        Task {
            let outcome = await task.start { event in continuation.yield(.event(event)) }
            continuation.yield(.outcome(outcome))
            continuation.finish()
        }
    }

    private enum Message: Sendable {
        case event(DownloadEvent)
        case outcome(DownloadOutcome)
    }

    private func handle(_ event: DownloadEvent, for id: UUID) {
        guard let index = index(of: id), runningID == id else { return }
        var item = entries[index].item
        switch event {
        case .started:
            if item.status != .stopping { item.status = .running }
        case .progress(let progress):
            item.progress = progress
        case .log(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { item.lastLog = trimmed }
        case .verifying:
            if item.status != .stopping { item.status = .verifying }
        case .finished:
            return // 以 start 的返回值为准（见 finish）
        }
        entries[index].item = item
        publish()
    }

    private func finish(_ id: UUID, outcome: DownloadOutcome) {
        if runningID == id { runningID = nil }
        guard let index = index(of: id) else { pump(); return }
        let cancelRequested = entries[index].cancelRequested
        switch outcome {
        case .completed(let result):
            entries[index].item.status = .completed(result)
            if let total = entries[index].item.progress?.total ?? entries[index].item.progress.map(\.bytes) {
                entries[index].item.progress = DownloadProgress(fraction: 1, bytes: total, total: total,
                                                                bytesPerSecond: nil, source: .progressBar)
            }
        case .paused:
            entries[index].item.status = .paused
        case .cancelled:
            break
        case .failed(let error):
            entries[index].item.status = error.kind == .cancelled ? .paused : .failed(error)
        }
        if cancelRequested || outcome == .cancelled {
            let request = entries[index].item.request
            entries.remove(at: index)
            Self.removeTemporaryFile(for: request)
        }
        publish()
        pump()
    }

    /// 取消时删除本 App 发起的下载留下的 `<目标>.tmp`（目标是文件路径时）。
    static func removeTemporaryFile(for request: DownloadRequest) {
        guard request.output.pathExtension.lowercased() == "ipa" else { return }
        let tmp = URL(fileURLWithPath: request.output.path + ".tmp")
        try? FileManager.default.removeItem(at: tmp)
    }
}
