import Foundation

/// 一次下载请求。`output` 可以是目标文件路径（推荐，`.ipa` 结尾）或已存在的目录。
public struct DownloadRequest: Sendable, Codable, Hashable {
    public var appID: Int64
    public var externalVersionID: String?
    public var purchase: Bool
    public var output: URL
    public var platform: String?
    /// 发起下载时的账号（多账号）；nil = 旧数据，视为当前账号。不影响 ipatool 参数。
    public var accountID: UUID?

    public init(appID: Int64, externalVersionID: String? = nil, purchase: Bool = false,
                output: URL, platform: String? = nil, accountID: UUID? = nil) {
        self.appID = appID
        self.externalVersionID = externalVersionID
        self.purchase = purchase
        self.output = output
        self.platform = platform
        self.accountID = accountID
    }

    /// ipatool 参数（不含 `--format json`；交互模式，以便得到进度条文本）。
    public var arguments: [String] {
        var args = ["download", "-i", String(appID)]
        if let externalVersionID, !externalVersionID.isEmpty { args += ["--external-version-id", externalVersionID] }
        if purchase { args.append("--purchase") }
        if let platform { args += ["--platform", platform] }
        args += ["-o", output.path]
        return args
    }
}

public struct DownloadResult: Sendable, Equatable {
    public let fileURL: URL
    public let purchased: Bool
    public let info: IPAInfo
}

public enum DownloadOutcome: Sendable, Equatable {
    case completed(DownloadResult)
    case paused
    case cancelled
    case failed(IpatoolError)
}

public enum DownloadEvent: Sendable, Equatable {
    case started
    case progress(DownloadProgress)
    /// ipatool 的非进度文本或 JSON 日志消息（便于界面显示「首次准备组件」等状态）。
    case log(String)
    case verifying
    case finished(DownloadOutcome)
}

/// 下载任务。暂停 = 终止子进程；继续 = 用同样参数再次 `start`（ipatool 依靠 `<目标>.tmp` 自动续传）。
public final class DownloadTask: @unchecked Sendable {
    public let request: DownloadRequest
    public let runner: IpatoolRunner
    public let pollInterval: TimeInterval

    private let lock = NSLock()
    private var process: IpatoolProcess?
    private var stopReason: DownloadOutcome?
    private var running = false

    public init(request: DownloadRequest, runner: IpatoolRunner, pollInterval: TimeInterval = 1.0) {
        self.request = request
        self.runner = runner
        self.pollInterval = pollInterval
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    /// 开始（或继续）下载，直到完成、暂停、取消或失败。
    @discardableResult
    public func start(onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        let alreadyRunning: Bool = lock.withLock {
            if running { return true }
            running = true
            stopReason = nil
            return false
        }
        if alreadyRunning { return .failed(IpatoolError(kind: .unknown, raw: "download already running")) }
        defer { lock.withLock { running = false; process = nil } }

        let outcome = await perform(onEvent: onEvent)
        onEvent(.finished(outcome))
        return outcome
    }

    public func pause() { stop(.paused) }
    public func cancel() { stop(.cancelled) }

    private func stop(_ reason: DownloadOutcome) {
        lock.lock()
        stopReason = reason
        let p = process
        lock.unlock()
        p?.cancel()
    }

    private func perform(onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        let proc: IpatoolProcess
        do {
            try FileManager.default.createDirectory(at: request.output.hasDirectoryPath || isDirectory(request.output)
                                                    ? request.output : request.output.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            proc = try runner.makeProcess(request.arguments, interactive: true)
        } catch let e as IpatoolError {
            return .failed(e)
        } catch {
            return .failed(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }

        let earlyStop: DownloadOutcome? = lock.withLock {
            if let reason = stopReason { return reason }
            process = proc
            return nil
        }
        if let earlyStop { return earlyStop }

        onEvent(.started)
        let tracker = ProgressTracker()
        let poller = Task { [request, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { break }
                guard tracker.shouldPoll(staleAfter: pollInterval * 2),
                      let size = Self.tempFileSize(for: request) else { continue }
                if let progress = tracker.fromFileSize(size) { onEvent(.progress(progress)) }
            }
        }

        let result: IpatoolProcess.Result
        do {
            result = try await proc.run(onLine: { line in
                switch line {
                case .text(let text):
                    if let progress = ProgressParser.parse(text) {
                        tracker.record(progress)
                        onEvent(.progress(progress))
                    } else {
                        onEvent(.log(text))
                    }
                case .json(let event):
                    if let message = event.message { onEvent(.log(message)) }
                }
            })
        } catch let e as IpatoolError {
            poller.cancel()
            return .failed(e)
        } catch {
            poller.cancel()
            return .failed(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }
        poller.cancel()

        let reason = lock.withLock { stopReason }
        if let reason, result.wasCancelled { return reason }

        do {
            try IpatoolRunner.check(result)
        } catch let e as IpatoolError {
            return e.kind == .cancelled ? .cancelled : .failed(e)
        } catch {
            return .failed(IpatoolError(kind: .unknown, raw: error.localizedDescription))
        }

        guard let event = result.events.last(where: { $0.success == true && $0["output"] != nil }),
              let path = event["output"]?.stringValue else {
            return .failed(IpatoolError(kind: .invalidOutput, raw: result.textLines.joined(separator: "\n")))
        }

        onEvent(.verifying)
        let fileURL = URL(fileURLWithPath: path)
        do {
            let info = try IPAInfo.read(from: fileURL)
            return .completed(DownloadResult(fileURL: fileURL, purchased: event["purchased"]?.boolValue ?? false, info: info))
        } catch let e as IpatoolError {
            return .failed(e)
        } catch {
            return .failed(IpatoolError(kind: .verificationFailed, raw: error.localizedDescription))
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// `<目标>.tmp` 的当前大小；目标是目录时，在目录中找名字含 `_<appID>` 的最新 `.tmp`。
    static func tempFileSize(for request: DownloadRequest) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: request.output.path, isDirectory: &isDir), isDir.boolValue {
            let marker = "_\(request.appID)"
            guard let items = try? fm.contentsOfDirectory(at: request.output,
                                                          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            let candidates = items.filter { $0.pathExtension == "tmp" && $0.lastPathComponent.contains(marker) }
            let newest = candidates.max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
            return newest.flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
        }
        let tmp = request.output.path + ".tmp"
        guard let attrs = try? fm.attributesOfItem(atPath: tmp), let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}

/// 记录最近一次进度条解析结果，进度条长时间没有更新时改用 `.tmp` 文件大小推算。
final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastParsedAt: Date?
    private var lastTotal: Int64?
    private var lastFileSample: (Date, Int64)?

    func record(_ progress: DownloadProgress) {
        lock.lock(); defer { lock.unlock() }
        lastParsedAt = Date()
        if let total = progress.total { lastTotal = total }
    }

    func shouldPoll(staleAfter interval: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let lastParsedAt else { return true }
        return Date().timeIntervalSince(lastParsedAt) > interval
    }

    func fromFileSize(_ size: Int64, now: Date = Date()) -> DownloadProgress? {
        lock.lock(); defer { lock.unlock() }
        var speed: Double?
        if let (t, s) = lastFileSample, now > t, size >= s {
            speed = Double(size - s) / now.timeIntervalSince(t)
        }
        lastFileSample = (now, size)
        let fraction = lastTotal.flatMap { $0 > 0 ? min(Double(size) / Double($0), 1) : nil }
        return DownloadProgress(fraction: fraction, bytes: size, total: lastTotal, bytesPerSecond: speed, source: .tempFile)
    }
}
