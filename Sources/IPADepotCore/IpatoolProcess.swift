import Foundation
import Darwin

/// 封装一次 ipatool 子进程调用：绝对路径启动、按行读取 stdout/stderr、解析 zerolog JSON 行、支持取消。
///
/// - stdout 每行先尝试按 JSON 解析，失败则作为文本回调（进度条文本走这里）。
/// - stderr 一律作为文本回调。
/// - 若提供 `terminal`，子进程的 stdin 与 stderr 接到伪终端从端（ipatool 的交互提示写在 stderr），
///   stdout 仍走管道以保证 JSON 干净；伪终端主端的原始输出通过 `onTerminalOutput` 交给调用方。
public final class IpatoolProcess: @unchecked Sendable {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let events: [IpatoolLogEvent]
        public let textLines: [String]
        public let wasCancelled: Bool

        /// 最后一条错误事件。
        public var errorEvent: IpatoolLogEvent? { events.last(where: { $0.isError }) }
        /// 最后一条带有指定字段的事件。
        public func lastEvent(containing key: String) -> IpatoolLogEvent? {
            events.last(where: { $0.fields[key] != nil })
        }
    }

    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL?
    public let terminal: PseudoTerminal?

    private let lock = NSLock()
    private var process: Process?
    private var cancelRequested = false
    private var started = false
    private let queue = DispatchQueue(label: "app.ipadepot.ipatool-process")

    public init(executableURL: URL,
                arguments: [String],
                environment: [String: String],
                currentDirectoryURL: URL? = nil,
                terminal: PseudoTerminal? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.terminal = terminal
    }

    public var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    /// 运行直到子进程退出且输出读完。Swift 任务被取消时会终止子进程，并返回 `wasCancelled == true` 的结果。
    public func run(onLine: (@Sendable (IpatoolLine) -> Void)? = nil,
                    onTerminalOutput: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                self.launch(onLine: onLine, onTerminalOutput: onTerminalOutput, continuation: continuation)
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// 终止子进程：先 SIGTERM，超过宽限期仍未退出则 SIGKILL。
    public func cancel(gracePeriod: TimeInterval = 3) {
        lock.lock()
        cancelRequested = true
        let proc = process
        lock.unlock()
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) { [weak proc] in
            if let proc, proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    // MARK: - 内部

    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var events: [IpatoolLogEvent] = []
        var textLines: [String] = []
        var stdoutDone = false
        var stderrDone = false
        var terminalDone = true
        var exitCode: Int32?
        var resumed = false
        var stdoutBuffer = LineBuffer()
        var stderrBuffer = LineBuffer()
        var terminalBuffer = LineBuffer()
        /// 持有读取器直到结束（DispatchSource 需要被强引用）。
        var readers: [FDReader] = []
    }

    private func launch(onLine: (@Sendable (IpatoolLine) -> Void)?,
                        onTerminalOutput: (@Sendable (String) -> Void)?,
                        continuation: CheckedContinuation<Result, Error>) {
        lock.lock()
        if started {
            lock.unlock()
            continuation.resume(throwing: IpatoolError(kind: .unknown, raw: "IpatoolProcess can only run once"))
            return
        }
        started = true
        let alreadyCancelled = cancelRequested
        lock.unlock()

        if alreadyCancelled {
            continuation.resume(returning: Result(exitCode: -1, events: [], textLines: [], wasCancelled: true))
            return
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            continuation.resume(throwing: IpatoolError(kind: .binaryNotFound, raw: executableURL.path))
            return
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        proc.environment = environment
        if let currentDirectoryURL { proc.currentDirectoryURL = currentDirectoryURL }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        if let terminal {
            let slave = FileHandle(fileDescriptor: terminal.slaveFD, closeOnDealloc: false)
            proc.standardInput = slave
            proc.standardError = slave
        } else {
            proc.standardInput = FileHandle.nullDevice
            proc.standardError = stderrPipe
        }

        let collector = Collector()
        if terminal != nil {
            collector.stderrDone = true
            collector.terminalDone = false
        }

        let finishIfReady: @Sendable () -> Void = { [weak self] in
            collector.lock.lock()
            guard !collector.resumed, collector.stdoutDone, collector.stderrDone, collector.terminalDone,
                  let code = collector.exitCode else {
                collector.lock.unlock()
                return
            }
            collector.resumed = true
            collector.readers = []
            let result = Result(exitCode: code,
                                events: collector.events,
                                textLines: collector.textLines,
                                wasCancelled: self?.isCancelled ?? false)
            collector.lock.unlock()
            self?.terminal?.closeMaster()
            continuation.resume(returning: result)
        }

        let deliver: @Sendable ([String], Bool) -> Void = { lines, isStdout in
            for line in lines {
                let parsed: IpatoolLine = isStdout ? IpatoolLineParser.parse(line) : .text(line)
                collector.lock.lock()
                switch parsed {
                case .json(let event): collector.events.append(event)
                case .text(let text): collector.textLines.append(text)
                }
                collector.lock.unlock()
                onLine?(parsed)
            }
        }

        let stdoutReader = FDReader(fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor, queue: queue,
            onData: { data in
                collector.lock.lock(); let lines = collector.stdoutBuffer.append(data); collector.lock.unlock()
                deliver(lines, true)
            },
            onEOF: {
                collector.lock.lock(); let lines = collector.stdoutBuffer.flush(); collector.lock.unlock()
                deliver(lines, true)
                collector.lock.lock(); collector.stdoutDone = true; collector.lock.unlock()
                finishIfReady()
            })

        var stderrReader: FDReader?
        if terminal == nil {
            stderrReader = FDReader(fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor, queue: queue,
                onData: { data in
                    collector.lock.lock(); let lines = collector.stderrBuffer.append(data); collector.lock.unlock()
                    deliver(lines, false)
                },
                onEOF: {
                    collector.lock.lock(); let lines = collector.stderrBuffer.flush(); collector.lock.unlock()
                    deliver(lines, false)
                    collector.lock.lock(); collector.stderrDone = true; collector.lock.unlock()
                    finishIfReady()
                })
        }

        var terminalReader: FDReader?
        if let terminal {
            terminalReader = FDReader(fileDescriptor: terminal.masterFD, queue: queue,
                onData: { data in
                    onTerminalOutput?(String(decoding: data, as: UTF8.self))
                    collector.lock.lock(); let lines = collector.terminalBuffer.append(data); collector.lock.unlock()
                    deliver(lines, false)
                },
                onEOF: {
                    collector.lock.lock(); let lines = collector.terminalBuffer.flush(); collector.lock.unlock()
                    deliver(lines, false)
                    collector.lock.lock(); collector.terminalDone = true; collector.lock.unlock()
                    finishIfReady()
                })
        }

        guard let stdoutReader, terminal != nil || stderrReader != nil, terminal == nil || terminalReader != nil else {
            continuation.resume(throwing: IpatoolError(kind: .unknown, raw: "failed to set up output readers"))
            return
        }

        collector.readers = [stdoutReader, stderrReader, terminalReader].compactMap { $0 }

        proc.terminationHandler = { process in
            collector.lock.lock(); collector.exitCode = process.terminationStatus; collector.lock.unlock()
            finishIfReady()
        }

        do {
            try proc.run()
        } catch {
            stdoutReader.cancel(); stderrReader?.cancel(); terminalReader?.cancel()
            collector.readers = []
            continuation.resume(throwing: IpatoolError(kind: .binaryNotFound, raw: "\(executableURL.path): \(error.localizedDescription)"))
            return
        }

        // 父进程关闭自己持有的写端/从端，子进程退出后读端才能收到 EOF。
        try? stdoutPipe.fileHandleForWriting.close()
        if terminal == nil { try? stderrPipe.fileHandleForWriting.close() }
        terminal?.closeSlave()

        stdoutReader.start()
        stderrReader?.start()
        terminalReader?.start()

        lock.lock()
        process = proc
        let cancelNow = cancelRequested
        lock.unlock()
        if cancelNow { cancel() }
    }
}
