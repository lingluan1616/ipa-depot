import XCTest
@testable import IPADepotCore

/// 真实 ipatool 只读冒烟。默认跳过；需要时这样运行：
/// TEST_RUNNER_IPADEPOT_SMOKE_IPATOOL=/opt/homebrew/bin/ipatool \
/// TEST_RUNNER_IPADEPOT_SMOKE_VENDOR=$PWD/vendor/ipatool/ipatool \
/// TEST_RUNNER_IPADEPOT_SMOKE_OUT=$PWD/build/smoke.txt \
/// xcodebuild test -scheme IPADepotCore -derivedDataPath build/DerivedData -only-testing:IPADepotCoreTests/SmokeTests
///
/// 只运行 `--version`、`search`、`list-versions`。search / list-versions 用登录时创建钥匙串条目的那份 ipatool，
/// 避免内置二进制读取钥匙串触发系统授权弹窗。
final class SmokeTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var paths: AppPaths!
    private var log: [String] = []

    override func setUpWithError() throws {
        guard env["IPADEPOT_SMOKE_IPATOOL"] != nil else { throw XCTSkip("未设置 IPADEPOT_SMOKE_IPATOOL，跳过真机冒烟") }
        paths = AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("IPADepotSmoke-\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        if let paths { try? FileManager.default.removeItem(at: paths.root) }
        if let out = env["IPADEPOT_SMOKE_OUT"], !log.isEmpty {
            let text = log.joined(separator: "\n") + "\n"
            if let handle = FileHandle(forWritingAtPath: out) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); handle.closeFile()
            } else {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }

    private var runner: IpatoolRunner {
        IpatoolRunner(executableURL: URL(fileURLWithPath: env["IPADEPOT_SMOKE_IPATOOL"]!), paths: paths)
    }

    func test1Version() async throws {
        for (label, path) in [("smoke ipatool", env["IPADEPOT_SMOKE_IPATOOL"]), ("vendor ipatool", env["IPADEPOT_SMOKE_VENDOR"])] {
            guard let path else { continue }
            let locator = IpatoolLocator(overridePath: path, fallbackPaths: [])
            let version = try await locator.detectVersion(paths: paths)
            log.append("[--version] \(label) \(try locator.locate().path) -> \(version)")
            XCTAssertEqual(version, "2.7.0")
        }
    }

    func test2Search() async throws {
        let apps = try await SearchService(runner: runner).search("音乐", limit: 3)
        log.append("[search \"音乐\" --limit 3] \(apps.count) 个结果")
        for app in apps {
            log.append("  - id=\(app.id) bundleID=\(app.bundleID) name=\(app.name) version=\(app.version) price=\(app.price) platforms=\(app.platforms)")
        }
        XCTAssertFalse(apps.isEmpty)
        XCTAssertLessThanOrEqual(apps.count, 3)
    }

    func test3ListVersions() async throws {
        let service = VersionService(runner: runner)
        let ids = try await service.listVersionIDs(appID: 1606306441)
        let cached = service.cache.load(appID: 1606306441)
        log.append("[list-versions -i 1606306441] \(ids.count) 个版本 ID，bundleID=\(cached?.bundleID ?? "-")")
        log.append("  前 3 个: \(ids.prefix(3).joined(separator: ", "))")
        log.append("  后 3 个: \(ids.suffix(3).joined(separator: ", "))")
        log.append("  缓存文件已写入: \(cached != nil)")
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(cached?.versionIDs, ids)
    }
}
