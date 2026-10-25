import Foundation
import XCTest
@testable import IPADepotCore

/// 每个测试用例独立的临时目录（`FileManager.default.temporaryDirectory/IPADepotCoreTests-<UUID>`），tearDown 删除。
class TempDirTestCase: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPADepotCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// 写一个可执行的假 ipatool 脚本。
    func makeScript(_ body: String, name: String = "fake-ipatool") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func makeRunner(executable: URL) -> IpatoolRunner {
        IpatoolRunner(executableURL: executable, paths: AppPaths(root: tempDir.appendingPathComponent("support")))
    }
}

func result(_ lines: [String], exitCode: Int32 = 0) -> IpatoolProcess.Result {
    var events: [IpatoolLogEvent] = []
    var text: [String] = []
    for line in lines {
        switch IpatoolLineParser.parse(line) {
        case .json(let e): events.append(e)
        case .text(let t): text.append(t)
        }
    }
    return IpatoolProcess.Result(exitCode: exitCode, events: events, textLines: text, wasCancelled: false)
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}
