import XCTest
@testable import IPADepotCore

final class ZipReaderTests: TempDirTestCase {
    private func makeIPA(deflate: Bool) throws -> URL {
        let app = tempDir.appendingPathComponent("src/Payload/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("PlugIns/Ext.appex"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.demo",
                                    "CFBundleShortVersionString": "3.8.5",
                                    "CFBundleVersion": "385",
                                    "Padding": String(repeating: "x", count: 4096)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: app.appendingPathComponent("Info.plist"))
        let ext = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.demo.ext"], format: .xml, options: 0)
        try ext.write(to: app.appendingPathComponent("PlugIns/Ext.appex/Info.plist"))
        let ipa = tempDir.appendingPathComponent(deflate ? "demo.ipa" : "stored.ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir.appendingPathComponent("src")
        zip.arguments = (deflate ? ["-q", "-r"] : ["-q", "-r", "-0"]) + [ipa.path, "Payload"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return ipa
    }

    func testReadsInfoPlistFromDeflatedAndStoredIPA() throws {
        for deflate in [true, false] {
            let info = try IPAInfo.read(from: try makeIPA(deflate: deflate))
            XCTAssertEqual(info.bundleIdentifier, "com.example.demo")
            XCTAssertEqual(info.shortVersion, "3.8.5")
            XCTAssertEqual(info.bundleVersion, "385")
            XCTAssertEqual(info.appName, "Demo")
        }
    }

    func testInvalidFilesFailVerification() throws {
        let bogus = tempDir.appendingPathComponent("bogus.ipa")
        try Data(repeating: 0x41, count: 1000).write(to: bogus)
        XCTAssertThrowsError(try IPAInfo.read(from: bogus)) { XCTAssertEqual(($0 as? IpatoolError)?.kind, .verificationFailed) }

        // 合法 zip 但没有 Payload/*.app/Info.plist
        let src = tempDir.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: src.appendingPathComponent("readme.txt"))
        let zipURL = tempDir.appendingPathComponent("plain.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = src
        zip.arguments = ["-q", zipURL.path, "readme.txt"]
        try zip.run(); zip.waitUntilExit()
        XCTAssertEqual(try ZipReader(url: zipURL).entries.map(\.name), ["readme.txt"])
        XCTAssertThrowsError(try IPAInfo.read(from: zipURL))
    }
}

/// 用假 ipatool 脚本验证进程封装、PTY 登录与下载流程（不依赖真实 ipatool、不联网）。
final class FakeIpatoolTests: TempDirTestCase {
    func testProcessParsesJSONAndTextLines() async throws {
        let script = try makeScript("""
        echo '{"level":"info","message":"hello","time":"t"}'
        printf 'downloading  50%% |█████     | (1/2 MB, 1 MB/s)\\r'
        echo 'warn on stderr' >&2
        echo '{"level":"info","success":true,"args":"'"$*"'","state":"'"$XDG_STATE_HOME"'"}'
        """)
        let runner = makeRunner(executable: script)
        let lines = Box<[IpatoolLine]>([])
        let result = try await runner.run(["search", "x"], onLine: { line in lines.mutate { $0.append(line) } })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(result.events.last?["args"]?.stringValue, "search x --format json --non-interactive")
        XCTAssertEqual(result.events.last?["state"]?.stringValue, runner.paths.stateDirectory.path)
        XCTAssertTrue(result.textLines.contains("warn on stderr"))
        XCTAssertNotNil(result.textLines.compactMap(ProgressParser.parse).first)
        XCTAssertEqual(lines.value.count, 4)
    }

    func testCancelTerminatesLongRunningProcess() async throws {
        let script = try makeScript("echo '{\"level\":\"info\",\"message\":\"start\"}'\nsleep 30\n")
        let process = try makeRunner(executable: script).makeProcess(["download"], interactive: true)
        let started = Date()
        Task { try? await Task.sleep(nanoseconds: 300_000_000); process.cancel(gracePeriod: 1) }
        let result = try await process.run()
        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testLoginSessionAnswersPromptsThroughPTYWithTwoFactor() async throws {
        let script = try makeScript("""
        for a in "$@"; do case "$a" in -p|--password|*s3cr3t*) echo '{"level":"error","error":"password leaked into argv","success":false}'; exit 1;; esac; done
        [ -t 0 ] || { echo '{"level":"error","error":"stdin is not a tty","success":false}'; exit 1; }
        printf 'enter Apple ID (email address or phone number): ' >&2
        read -r email
        printf 'enter password: ' >&2
        read -r pw
        echo '{"level":"info","message":"preparing authentication; the first login may take a few minutes"}'
        [ "$pw" = "s3cr3t pass" ] || { echo '{"level":"error","error":"bad password","success":false}'; exit 1; }
        printf 'enter 2FA code: ' >&2
        read -r code
        [ "$code" = "123456" ] || { echo '{"level":"error","error":"apple did not complete verification; try a fresh 2FA code","success":false}'; exit 1; }
        echo '{"level":"info","name":"Test User","email":"'"$email"'","success":true}'
        """)
        let session = LoginSession(runner: makeRunner(executable: script))
        let events = Box<[LoginEvent]>([])
        let outcome = await session.login(email: "user@example.com", password: "s3cr3t pass") { event in
            events.mutate { $0.append(event) }
            if event == .needsTwoFactor {
                let badRejected = (try? session.submitTwoFactorCode("12ab")) == nil
                XCTAssertTrue(badRejected, "非 6 位数字应在本地被拒绝")
                do { try session.submitTwoFactorCode("123456") } catch { XCTFail("submit failed: \(error)") }
            }
        }
        XCTAssertEqual(try outcome.get(), AccountInfo(name: "Test User", email: "user@example.com"))
        XCTAssertTrue(events.value.contains(.preparing))
        XCTAssertTrue(events.value.contains(.needsTwoFactor))
        XCTAssertEqual(events.value.last, .succeeded(AccountInfo(name: "Test User", email: "user@example.com")))
        XCTAssertEqual(session.state, .succeeded(AccountInfo(name: "Test User", email: "user@example.com")))
    }

    func testLoginSessionMapsFailure() async throws {
        let script = try makeScript("""
        printf 'enter Apple ID: ' >&2; read -r e
        printf 'enter password: ' >&2; read -r p
        echo '{"level":"error","error":"account is disabled","success":false}'; exit 1
        """)
        let outcome = await LoginSession(runner: makeRunner(executable: script)).login(email: "a@b.c", password: "x") { _ in }
        guard case .failure(let error) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .accountDisabled)
    }

    func testDownloadTaskReportsProgressAndVerifiesIPA() async throws {
        // 先做一个真实 zip 结构的 IPA，假 ipatool 把它“下载”到 -o 指定的位置
        let source = tempDir.appendingPathComponent("payload.ipa")
        let app = tempDir.appendingPathComponent("src/Payload/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.demo",
                                                              "CFBundleShortVersionString": "1.2.3"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = tempDir.appendingPathComponent("src")
        zip.arguments = ["-q", "-r", source.path, "Payload"]
        try zip.run(); zip.waitUntilExit()

        let script = try makeScript("""
        out=""; prev=""
        for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
        for a in "$@"; do [ "$a" = "--non-interactive" ] && { echo '{"level":"error","error":"should be interactive","success":false}'; exit 1; }; done
        printf 'downloading   0%% |          | (0 B/2 MB)\\r'
        printf 'downloading  50%% |█████     | (1/2 MB, 1.0 MB/s)\\r'
        printf 'downloading 100%% |██████████| (2/2 MB, 1.0 MB/s)\\r'
        cp "\(source.path)" "$out"
        echo '{"level":"info","output":"'"$out"'","purchased":false,"success":true}'
        """)
        let target = tempDir.appendingPathComponent("downloads/demo.ipa")
        let task = DownloadTask(request: DownloadRequest(appID: 1, output: target), runner: makeRunner(executable: script))
        let events = Box<[DownloadEvent]>([])
        let outcome = await task.start { e in events.mutate { $0.append(e) } }
        guard case .completed(let r) = outcome else { return XCTFail("unexpected outcome \(outcome)") }
        XCTAssertEqual(r.fileURL.path, target.path)
        XCTAssertEqual(r.info.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(r.info.shortVersion, "1.2.3")
        let fractions = events.value.compactMap { e -> Double? in if case .progress(let p) = e { return p.fraction }; return nil }
        XCTAssertEqual(fractions, [0, 0.5, 1])
        XCTAssertTrue(events.value.contains(.verifying))
    }

    func testDownloadPauseReturnsPausedAndResumeReruns() async throws {
        let counter = tempDir.appendingPathComponent("runs")
        let script = try makeScript("""
        echo x >> "\(counter.path)"
        printf 'downloading  10%% |█         | (1/10 MB, 1 MB/s)\\r'
        sleep 30
        """)
        let task = DownloadTask(request: DownloadRequest(appID: 1, output: tempDir.appendingPathComponent("a.ipa")),
                                runner: makeRunner(executable: script))
        for _ in 0..<2 {
            let pauser = Task { try? await Task.sleep(nanoseconds: 500_000_000); task.pause() }
            let outcome = await task.start { _ in }
            _ = await pauser.value
            XCTAssertEqual(outcome, .paused)
        }
        XCTAssertEqual(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count, 2)
    }
}
