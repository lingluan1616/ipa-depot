import XCTest
@testable import IPADepotCore

final class IpatoolErrorMapperTests: XCTestCase {
    func testKnownStringsMapToKinds() {
        let cases: [(String, IpatoolErrorKind)] = [
            ("failed to get product: license is required", .licenseRequired),
            ("license already exists", .licenseAlreadyExists),
            ("password token is expired", .passwordTokenExpired),
            ("account is disabled", .accountDisabled),
            ("auth code is required", .authCodeRequired),
            ("2FA code must contain exactly six digits", .invalidAuthCodeFormat),
            ("apple did not complete verification; try a fresh 2FA code", .verificationIncomplete),
            ("app not found", .appNotFound),
            ("failed to get account: The specified item could not be found in the keychain.", .notLoggedIn),
            ("A keychain cannot be found to store \"account\"", .keychainNotFound),
            ("failed to validate package platform: downloaded package does not declare iPhoneOS support", .packagePlatformMismatch),
            ("something entirely new", .unknown),
        ]
        for (raw, kind) in cases {
            let error = IpatoolErrorMapper.map(raw, exitCode: 1)
            XCTAssertEqual(error.kind, kind, raw)
            XCTAssertEqual(error.raw, raw, "原始英文必须保留")
            XCTAssertEqual(error.exitCode, 1)
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testNetworkErrorsAndMainlandHint() {
        let raw = #"request failed: Post "https://p47-buy.itunes.apple.com/WebObjects/MZBuy.woa/wa/buyProduct": dial tcp: lookup p47-buy.itunes.apple.com: no such host"#
        let error = IpatoolErrorMapper.map(raw)
        XCTAssertEqual(error.kind, .networkUnreachable)
        XCTAssertTrue(error.message.contains("p*-buy.itunes.apple.com"))
        XCTAssertTrue(error.message.contains("中国大陆"))
        XCTAssertEqual(IpatoolErrorMapper.map("read tcp 10.0.0.2:5000: i/o timeout").kind, .networkUnreachable)
        XCTAssertEqual(IpatoolErrorMapper.map("connect: connection refused").kind, .networkUnreachable)
        XCTAssertEqual(error.errorDescription, error.message)
    }

    func testRunnerCheckUsesErrorEventsExitCodeAndCancellation() {
        let failing = result([#"{"level":"error","error":"license is required","success":false}"#], exitCode: 1)
        XCTAssertThrowsError(try IpatoolRunner.check(failing)) { error in
            XCTAssertEqual((error as? IpatoolError)?.kind, .licenseRequired)
        }
        XCTAssertThrowsError(try IpatoolRunner.check(result(["panic: boom"], exitCode: 2))) { error in
            XCTAssertEqual((error as? IpatoolError)?.raw, "panic: boom")
        }
        let cancelled = IpatoolProcess.Result(exitCode: 15, events: [], textLines: [], wasCancelled: true)
        XCTAssertThrowsError(try IpatoolRunner.check(cancelled)) { error in
            XCTAssertEqual((error as? IpatoolError)?.kind, .cancelled)
        }
        XCTAssertNoThrow(try IpatoolRunner.check(result([#"{"level":"info","success":true}"#])))
    }
}

final class VersionCacheTests: TempDirTestCase {
    func testRoundTripAndMissing() throws {
        let cache = VersionCache(directory: tempDir.appendingPathComponent("cache/versions"))
        XCTAssertNil(cache.load(appID: 1606306441))
        let meta = VersionMetadata(externalVersionID: "1", displayVersion: "1.0.0",
                                   releaseDate: Date(timeIntervalSince1970: 1_700_000_000))
        let entry = CachedVersions(appID: 1606306441, bundleID: "com.example", versionIDs: ["1", "2"],
                                   metadata: ["1": meta], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try cache.save(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("cache/versions/1606306441.json").path))
        XCTAssertEqual(cache.load(appID: 1606306441), entry)
        cache.remove(appID: 1606306441)
        XCTAssertNil(cache.load(appID: 1606306441))
    }

    func testCorruptCacheIsIgnored() throws {
        let cache = VersionCache(directory: tempDir)
        try Data("not json".utf8).write(to: cache.fileURL(appID: 7))
        XCTAssertNil(cache.load(appID: 7))
    }

    func testMetadataBatchUsesCacheWithoutRunningIpatool() async throws {
        // 可执行文件不存在：若真的去跑 ipatool 会抛 binaryNotFound，因此全部命中缓存才能通过
        let runner = IpatoolRunner(executableURL: tempDir.appendingPathComponent("missing"),
                                   paths: AppPaths(root: tempDir))
        let service = VersionService(runner: runner)
        let metas = ["a", "b"].map { VersionMetadata(externalVersionID: $0, displayVersion: "v\($0)", releaseDate: nil) }
        try service.cache.save(CachedVersions(appID: 9, versionIDs: ["a", "b"],
                                              metadata: Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })))
        let seen = Box<[String]>([])
        let out = try await service.metadata(appID: 9, versionIDs: ["b", "a"]) { m in seen.mutate { $0.append(m.id) } }
        XCTAssertEqual(out.map(\.id), ["b", "a"])
        XCTAssertEqual(Set(seen.value), ["a", "b"])
    }
}

final class ArgumentTests: XCTestCase {
    func testDownloadArgumentsAreInteractive() {
        let req = DownloadRequest(appID: 1606306441, externalVersionID: "8888", purchase: true,
                                  output: URL(fileURLWithPath: "/tmp/x/app.ipa"))
        let args = IpatoolRunner.arguments(req.arguments, interactive: true)
        XCTAssertEqual(args, ["download", "-i", "1606306441", "--external-version-id", "8888", "--purchase",
                              "-o", "/tmp/x/app.ipa", "--format", "json"])
        XCTAssertFalse(args.contains("--non-interactive"))
    }

    func testSearchAndLoginArguments() {
        XCTAssertEqual(IpatoolRunner.arguments(SearchService.arguments(term: "音乐", limit: 3, platform: "iphone"), interactive: false),
                       ["search", "音乐", "--limit", "3", "--platform", "iphone", "--format", "json", "--non-interactive"])
        let login = IpatoolRunner.arguments(LoginSession.arguments, interactive: true)
        XCTAssertEqual(login, ["auth", "login", "--format", "json"])
    }

    func testEnvironmentSetsStateHomeButKeepsHome() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IPADepotCoreTests-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let env = try IpatoolEnvironment.make(base: ["HOME": "/Users/someone", "PATH": "/usr/bin"], paths: AppPaths(root: root))
        XCTAssertEqual(env["HOME"], "/Users/someone")
        XCTAssertEqual(env["XDG_STATE_HOME"], root.appendingPathComponent("state").path)
        XCTAssertEqual(env["PATH"], "/usr/bin")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state").path, isDirectory: &isDir) && isDir.boolValue)
    }

    func testLocatorPrefersOverrideThenFallback() throws {
        let locator = IpatoolLocator(bundle: Bundle(for: ArgumentTests.self), overridePath: "/nonexistent/ipatool",
                                     fallbackPaths: ["/bin/ls"])
        XCTAssertEqual(locator.candidates.first?.path, "/nonexistent/ipatool")
        XCTAssertEqual(try locator.locate().path, "/bin/ls")
        let none = IpatoolLocator(bundle: Bundle(for: ArgumentTests.self), fallbackPaths: [])
        XCTAssertThrowsError(try none.locate()) { XCTAssertEqual(($0 as? IpatoolError)?.kind, .binaryNotFound) }
    }
}
