import Foundation
import XCTest
@testable import IPADepotCore

// MARK: - 测试替身

/// 可手动控制的下载任务：start 挂起直到 finish / pause / cancel。
final class FakeDownloadTask: DownloadTasking, @unchecked Sendable {
    let request: DownloadRequest
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadOutcome, Never>?
    private var handler: (@Sendable (DownloadEvent) -> Void)?
    private var _startCount = 0
    private var _cancelCount = 0

    init(request: DownloadRequest) { self.request = request }

    var startCount: Int { lock.withLock { _startCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var isWaiting: Bool { lock.withLock { continuation != nil } }

    func start(onEvent: @escaping @Sendable (DownloadEvent) -> Void) async -> DownloadOutcome {
        await withCheckedContinuation { c in
            lock.withLock {
                continuation = c
                handler = onEvent
                _startCount += 1
            }
            onEvent(.started)
        }
    }

    func emit(_ event: DownloadEvent) { lock.withLock { handler }?(event) }

    func finish(_ outcome: DownloadOutcome) {
        let c: CheckedContinuation<DownloadOutcome, Never>? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume(returning: outcome)
    }

    func pause() { finish(.paused) }
    func cancel() {
        lock.withLock { _cancelCount += 1 }
        finish(.cancelled)
    }
}

final class FakeTaskFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [FakeDownloadTask] = []

    func make(_ request: DownloadRequest) -> DownloadTasking {
        let task = FakeDownloadTask(request: request)
        lock.withLock { tasks.append(task) }
        return task
    }

    var all: [FakeDownloadTask] { lock.withLock { tasks } }
    subscript(i: Int) -> FakeDownloadTask { all[i] }
}

struct FakeHTTP: HTTPFetching {
    let responses: @Sendable (URL) -> (Data, Int)?
    let log: Box<[URL]>

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        log.mutate { $0.append(url) }
        guard let r = responses(url) else { throw URLError(.notConnectedToInternet) }
        return r
    }
}

/// 轮询等待条件成立（最长 timeout 秒）。
func waitUntil(timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("等待超时", file: file, line: line)
}

func sampleResult(_ url: URL, version: String = "1.0") -> DownloadResult {
    DownloadResult(fileURL: url, purchased: false,
                   info: IPAInfo(bundleIdentifier: "com.example.app", shortVersion: version, bundleVersion: "1", appName: "Example"))
}

// MARK: - Locator

final class LocatorPhase2Tests: XCTestCase {
    func testEnvironmentOverrideComesBeforeBundleAndFallbacks() throws {
        let locator = IpatoolLocator(bundle: Bundle(for: LocatorPhase2Tests.self),
                                     environment: [IpatoolLocator.environmentOverrideKey: "/bin/ls"],
                                     fallbackPaths: ["/bin/cat"])
        XCTAssertEqual(locator.candidates.first?.path, "/bin/ls")
        XCTAssertEqual(try locator.locate().path, "/bin/ls")
    }

    func testNonExecutableEnvironmentOverrideIsSkipped() throws {
        let locator = IpatoolLocator(bundle: Bundle(for: LocatorPhase2Tests.self),
                                     environment: [IpatoolLocator.environmentOverrideKey: "/nonexistent/ipatool"],
                                     fallbackPaths: ["/bin/cat"])
        XCTAssertEqual(try locator.locate().path, "/bin/cat")
        let empty = IpatoolLocator(bundle: Bundle(for: LocatorPhase2Tests.self),
                                   environment: [IpatoolLocator.environmentOverrideKey: ""], fallbackPaths: [])
        XCTAssertNil(empty.environmentOverridePath)
    }

    func testSAPCertificateEOFIsNetworkError() {
        // 2026-10-26 界面冒烟中实测到的原始错误
        let raw = #"failed to initialize SAP action signer: create SAP signer: fetch SAP certificate: send SAP request: Get "https://s.mzstatic.com/sap/setupCert.plist": unexpected EOF"#
        XCTAssertEqual(IpatoolErrorMapper.map(raw).kind, .networkUnreachable)
    }

    func testDebugFallbackOrder() {
        #if DEBUG
        XCTAssertEqual(IpatoolLocator.developmentFallbacks, ["/opt/homebrew/bin/ipatool", "/usr/local/bin/ipatool"])
        XCTAssertTrue(IpatoolLocator.allowsEnvironmentOverride)
        #else
        XCTAssertEqual(IpatoolLocator.developmentFallbacks, [])
        #endif
    }
}

// MARK: - DownloadQueue

final class DownloadQueueTests: TempDirTestCase {
    private func request(_ name: String) -> DownloadRequest {
        DownloadRequest(appID: testAppID(name), output: tempDir.appendingPathComponent("\(name).ipa"))
    }

    private func status(_ queue: DownloadQueue, _ id: UUID) async -> DownloadItemStatus? {
        await queue.item(id)?.status
    }

    func testRunsOneTaskAtATime() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let a = await queue.add(request("a"))
        let b = await queue.add(request("b"))
        await waitUntil { factory.all.count == 2 && factory[0].isWaiting }
        let sa = await status(queue, a), sb = await status(queue, b)
        XCTAssertEqual(sa, .running)
        XCTAssertEqual(sb, .queued)
        XCTAssertEqual(factory[1].startCount, 0)

        let url = tempDir.appendingPathComponent("a.ipa")
        factory[0].finish(.completed(sampleResult(url)))
        await waitUntil { factory[1].isWaiting }
        let sa2 = await status(queue, a)
        XCTAssertEqual(sa2, .completed(sampleResult(url)))
        let sb2 = await status(queue, b)
        XCTAssertEqual(sb2, .running)
    }

    func testPauseAndResumeRunningTask() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let id = await queue.add(request("a"))
        await waitUntil { factory.all.first?.isWaiting == true }
        await queue.pause(id)
        await waitUntil { await self.status(queue, id) == .paused }
        await queue.resume(id)
        await waitUntil { factory[0].startCount == 2 && factory[0].isWaiting }
        let s = await status(queue, id)
        XCTAssertEqual(s, .running)
    }

    func testPausedQueuedItemIsSkipped() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        _ = await queue.add(request("a"))
        let b = await queue.add(request("b"))
        let c = await queue.add(request("c"))
        await queue.pause(b)
        await waitUntil { factory.all.count == 3 && factory[0].isWaiting }
        factory[0].finish(.completed(sampleResult(self.tempDir.appendingPathComponent("a.ipa"))))
        await waitUntil { factory[2].isWaiting }
        let sb = await status(queue, b), sc = await status(queue, c)
        XCTAssertEqual(sb, .paused)
        XCTAssertEqual(sc, .running)
        XCTAssertEqual(factory[1].startCount, 0)
    }

    func testCancelRunningRemovesItemAndTempFile() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let req = request("a")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: req.output.path + ".tmp"))
        let id = await queue.add(req)
        await waitUntil { factory.all.first?.isWaiting == true }
        await queue.cancel(id)
        await waitUntil { await queue.items.isEmpty }
        XCTAssertEqual(factory[0].cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: req.output.path + ".tmp"))
    }

    func testCancelQueuedRemovesImmediately() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        _ = await queue.add(request("a"))
        let b = await queue.add(request("b"))
        await queue.cancel(b)
        let ids = await queue.items.map(\.id)
        XCTAssertFalse(ids.contains(b))
        XCTAssertEqual(ids.count, 1)
    }

    func testFailureThenRetry() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let id = await queue.add(request("a"))
        await waitUntil { factory.all.first?.isWaiting == true }
        let error = IpatoolError(kind: .networkUnreachable, raw: "dial tcp: i/o timeout")
        factory[0].finish(.failed(error))
        await waitUntil { await self.status(queue, id) == .failed(error) }
        await queue.resume(id)
        await waitUntil { factory[0].startCount == 2 }
    }

    func testProgressAndLogEventsUpdateItemInOrder() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let id = await queue.add(request("a"))
        await waitUntil { factory.all.first?.isWaiting == true }
        let p = DownloadProgress(fraction: 0.5, bytes: 50, total: 100, bytesPerSecond: 10, source: .progressBar)
        factory[0].emit(.log("preparing kbsync"))
        factory[0].emit(.progress(p))
        factory[0].emit(.verifying)
        await waitUntil { await self.status(queue, id) == .verifying }
        let item = await queue.item(id)
        XCTAssertEqual(item?.progress, p)
        XCTAssertEqual(item?.lastLog, "preparing kbsync")
    }

    func testUpdatesStreamEmitsInitialAndChanges() async throws {
        let factory = FakeTaskFactory()
        let queue = DownloadQueue(makeTask: { factory.make($0) })
        let stream = await queue.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 0)
        _ = await queue.add(request("a"))
        let second = await iterator.next()
        XCTAssertEqual(second?.count, 1)
    }
}

// MARK: - 文件名、记录、目录占用

final class FileNamerAndStoreTests: TempDirTestCase {
    func testSanitizeReplacesIllegalCharacters() {
        XCTAssertEqual(DownloadFileNamer.sanitize("QQ音乐 - 听我/想听:*?"), "QQ音乐 - 听我_想听")
        XCTAssertEqual(DownloadFileNamer.sanitize("..hidden"), "hidden")
        XCTAssertEqual(DownloadFileNamer.sanitize("  \n "), "app")
        XCTAssertEqual(DownloadFileNamer.baseName(name: "谜底黑胶", version: "3.8.5"), "谜底黑胶_3.8.5")
        XCTAssertEqual(DownloadFileNamer.baseName(name: "A|B", version: ""), "A_B")
    }

    func testUniqueURLAddsSequenceForExistingReservedAndTemp() throws {
        let first = DownloadFileNamer.uniqueURL(in: tempDir, name: "App", version: "1.0")
        XCTAssertEqual(first.lastPathComponent, "App_1.0.ipa")
        try Data().write(to: first)
        let second = DownloadFileNamer.uniqueURL(in: tempDir, name: "App", version: "1.0")
        XCTAssertEqual(second.lastPathComponent, "App_1.0 (2).ipa")
        try Data().write(to: URL(fileURLWithPath: second.path + ".tmp"))
        let reserved = tempDir.appendingPathComponent("App_1.0 (3).ipa").standardizedFileURL.path
        let fourth = DownloadFileNamer.uniqueURL(in: tempDir, name: "App", version: "1.0", reserved: [reserved])
        XCTAssertEqual(fourth.lastPathComponent, "App_1.0 (4).ipa")
    }

    func testHistoryStoreRoundTripAndCorruptFile() throws {
        let store = HistoryStore(fileURL: tempDir.appendingPathComponent("sub/history.json"))
        XCTAssertEqual(store.load(), [])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let record = DownloadRecord(appID: 7, name: "名称", bundleID: "com.a", version: "1.2", externalVersionID: "88",
                                    size: 123, path: "/tmp/x.ipa", completedAt: date)
        try store.save([record])
        XCTAssertEqual(store.load(), [record])
        try Data("{not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), [])
    }

    func testDirectoryUsageSizeAndRemoveContents() throws {
        let dir = tempDir.appendingPathComponent("cache/versions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: dir.appendingPathComponent("1.json"))
        try Data(count: 24).write(to: dir.appendingPathComponent("2.json"))
        XCTAssertEqual(DirectoryUsage.size(of: dir), 1024)
        XCTAssertEqual(DirectoryUsage.size(of: tempDir.appendingPathComponent("missing")), 0)
        try DirectoryUsage.removeContents(of: dir)
        XCTAssertEqual(DirectoryUsage.size(of: dir), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testAppPathsLayout() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/x/IPA Depot"))
        XCTAssertEqual(paths.artworkCacheDirectory.path, "/x/IPA Depot/cache/artwork")
        XCTAssertEqual(paths.historyFile.path, "/x/IPA Depot/history.json")
    }
}

// MARK: - iTunes Lookup 与更新检查

final class LookupAndUpdateTests: TempDirTestCase {
    static let lookupJSON = #"{"resultCount":1,"results":[{"artworkUrl100":"https://is1.example.com/100x100bb.jpg","artistName":"Example Inc."}]}"#
    static let emptyJSON = #"{"resultCount":0,"results":[]}"#

    func testParseLookup() {
        let info = AppLookupService.parse(Data(Self.lookupJSON.utf8), appID: 5, country: "cn")
        XCTAssertEqual(info?.artworkURL?.absoluteString, "https://is1.example.com/100x100bb.jpg")
        XCTAssertEqual(info?.artistName, "Example Inc.")
        XCTAssertNil(AppLookupService.parse(Data(Self.emptyJSON.utf8), appID: 5, country: "cn"))
    }

    func testCountryFallbackOrderAndDiskCache() async throws {
        let log = Box<[URL]>([])
        let http = FakeHTTP(responses: { url in
            if url.absoluteString.contains("country=cn") { return (Data(Self.emptyJSON.utf8), 200) }
            if url.absoluteString.contains("country=us") { return (Data(Self.lookupJSON.utf8), 200) }
            if url.host == "is1.example.com" { return (Data([0x89, 0x50]), 200) }
            return nil
        }, log: log)
        let dir = tempDir.appendingPathComponent("artwork")
        let service = AppLookupService(directory: dir, http: http)
        let info = await service.info(appID: 42)
        XCTAssertEqual(info?.country, "us")
        XCTAssertEqual(log.value.map { $0.query ?? "" }, ["id=42&country=cn", "id=42&country=us"])
        let file = await service.artworkFile(appID: 42)
        XCTAssertNotNil(file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("42.json").path))

        // 新实例：从磁盘缓存读取，不再联网
        let countBefore = log.value.count
        let again = AppLookupService(directory: dir, http: http)
        let cached = await again.info(appID: 42)
        let cachedFile = await again.artworkFile(appID: 42)
        XCTAssertEqual(cached, info)
        XCTAssertEqual(cachedFile, file)
        XCTAssertEqual(log.value.count, countBefore)
    }

    func testLookupFailureReturnsNilWithoutRetrying() async {
        let log = Box<[URL]>([])
        let service = AppLookupService(directory: tempDir, http: FakeHTTP(responses: { _ in nil }, log: log))
        let info = await service.info(appID: 1)
        let file = await service.artworkFile(appID: 1)
        XCTAssertNil(info)
        XCTAssertNil(file)
        XCTAssertEqual(log.value.count, 3) // cn / us / jp 各一次，第二次调用不再请求
    }

    func testVersionComparator() {
        XCTAssertEqual(VersionComparator.compare("v0.2.0", "0.1.9"), .orderedDescending)
        XCTAssertEqual(VersionComparator.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("1.0.0-beta.1", "1.0.1"), .orderedAscending)
        XCTAssertEqual(VersionComparator.normalize("V2.7.0"), "2.7.0")
    }

    func testUpdateChecker() async throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/o/ipa-depot/releases/tag/v0.2.0","name":"0.2.0"}"#
        let log = Box<[URL]>([])
        let checker = UpdateChecker(owner: "o", http: FakeHTTP(responses: { _ in (Data(json.utf8), 200) }, log: log))
        XCTAssertEqual(checker.latestReleaseURL.absoluteString, "https://api.github.com/repos/o/ipa-depot/releases/latest")
        let newer = try await checker.check(currentVersion: "0.1.0")
        guard case .updateAvailable(let release) = newer else { return XCTFail("应提示新版本") }
        XCTAssertEqual(release.version, "0.2.0")
        let same = try await checker.check(currentVersion: "0.2.0")
        XCTAssertEqual(same, .upToDate(latest: "0.2.0"))

        let failing = UpdateChecker(owner: "o", http: FakeHTTP(responses: { _ in (Data("{}".utf8), 404) }, log: log))
        do {
            _ = try await failing.check(currentVersion: "0.1.0")
            XCTFail("应抛错")
        } catch let error as IpatoolError {
            XCTAssertEqual(error.raw, "GitHub API HTTP 404")
        }
    }
}
