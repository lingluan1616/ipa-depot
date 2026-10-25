import Foundation
import Darwin

/// 基于 DispatchSource 的文件描述符读取器。
/// 读到 0 字节或 EIO（伪终端从端全部关闭）视为结束。内部 dup 一份 fd，结束时关闭这份副本。
final class FDReader: @unchecked Sendable {
    private let fd: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var finished = false
    private var started = false

    init?(fileDescriptor: Int32, queue: DispatchQueue, onData: @escaping (Data) -> Void, onEOF: @escaping () -> Void) {
        let copy = dup(fileDescriptor)
        guard copy >= 0 else { return nil }
        fd = copy
        source = DispatchSource.makeReadSource(fileDescriptor: copy, queue: queue)
        let bufferSize = 64 * 1024
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let n = buffer.withUnsafeMutableBytes { Darwin.read(self.fd, $0.baseAddress, bufferSize) }
            if n > 0 {
                onData(Data(buffer[0..<n]))
            } else if n == 0 {
                self.finish(onEOF)
            } else {
                let err = errno
                if err == EAGAIN || err == EINTR { return }
                self.finish(onEOF) // EIO 等
            }
        }
        source.setCancelHandler { [fd = copy] in
            Darwin.close(fd)
        }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !finished else { return }
        started = true
        source.resume()
    }

    /// 主动停止（不触发 onEOF）。
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        source.cancel()
        if !started {
            // 挂起状态的 DispatchSource 被释放会崩溃，先恢复再让取消生效
            started = true
            source.resume()
        }
    }

    deinit {
        cancel()
    }

    private func finish(_ onEOF: () -> Void) {
        lock.lock()
        let already = finished
        finished = true
        lock.unlock()
        guard !already else { return }
        source.cancel()
        onEOF()
    }
}
