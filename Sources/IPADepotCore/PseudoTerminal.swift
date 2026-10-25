import Foundation
import Darwin

/// 伪终端（PTY）。用于以交互模式运行 `ipatool auth login`，把密码写进终端而不是命令行参数。
public final class PseudoTerminal: @unchecked Sendable {
    public let masterFD: Int32
    public private(set) var slaveFD: Int32
    public let slavePath: String
    private let lock = NSLock()
    private var masterClosed = false

    public init(disableEcho: Bool = true) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PseudoTerminal.posixError("posix_openpt") }
        guard grantpt(master) == 0, unlockpt(master) == 0, let namePtr = ptsname(master) else {
            let error = PseudoTerminal.posixError("grantpt/unlockpt/ptsname")
            Darwin.close(master)
            throw error
        }
        let path = String(cString: namePtr)
        let slave = Darwin.open(path, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            let error = PseudoTerminal.posixError("open slave")
            Darwin.close(master)
            throw error
        }
        if disableEcho {
            var attrs = termios()
            if tcgetattr(slave, &attrs) == 0 {
                attrs.c_lflag &= ~tcflag_t(ECHO | ECHONL)
                _ = tcsetattr(slave, TCSANOW, &attrs)
            }
        }
        masterFD = master
        slaveFD = slave
        slavePath = path
    }

    deinit {
        closeSlave()
        closeMaster()
    }

    /// 子进程启动后，父进程应关闭自己持有的从端，这样子进程退出后读主端能收到 EIO 结束。
    public func closeSlave() {
        lock.lock()
        defer { lock.unlock() }
        if slaveFD >= 0 {
            Darwin.close(slaveFD)
            slaveFD = -1
        }
    }

    public func closeMaster() {
        lock.lock()
        defer { lock.unlock() }
        if !masterClosed {
            Darwin.close(masterFD)
            masterClosed = true
        }
    }

    /// 向终端写入文本（相当于用户键入）。
    public func write(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !masterClosed else { throw IpatoolError(kind: .cancelled, raw: "terminal closed") }
        var bytes = Array(text.utf8)
        defer { for i in bytes.indices { bytes[i] = 0 } } // 尽量不在内存里留下密码副本
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(masterFD, ptr.baseAddress! + offset, bytes.count - offset)
            }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw PseudoTerminal.posixError("write")
            }
            offset += n
        }
    }

    static func posixError(_ what: String) -> IpatoolError {
        IpatoolError(kind: .unknown, raw: "\(what) failed: \(String(cString: strerror(errno)))")
    }
}
