import XCTest
@testable import IPADepotCore

final class LineBufferTests: XCTestCase {
    func testSplitsOnNewlineAndCarriageReturn() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("a\nb\rc".utf8)), ["a", "b"])
        XCTAssertEqual(buffer.pendingText, "c")
        XCTAssertEqual(buffer.append(Data("\r\n\n".utf8)), ["c"])
        XCTAssertEqual(buffer.flush(), [])
    }

    func testUTF8SplitAcrossChunksAndANSIStripped() {
        var buffer = LineBuffer()
        let bytes = Array("音乐\n".utf8)
        XCTAssertEqual(buffer.append(Data(bytes[0..<2])), [])
        XCTAssertEqual(buffer.append(Data(bytes[2...])), ["音乐"])
        XCTAssertEqual(buffer.append(Data("\u{1B}[2K\u{1B}[1Gdownloading 5%\n".utf8)), ["downloading 5%"])
        _ = buffer.append(Data("tail".utf8))
        XCTAssertEqual(buffer.flush(), ["tail"])
    }
}

final class IpatoolLineParserTests: XCTestCase {
    func testErrorLine() {
        let line = #"{"level":"error","error":"either the app ID or the bundle identifier must be specified","success":false,"time":"2026-10-26T03:26:57+08:00"}"#
        guard case .json(let event) = IpatoolLineParser.parse(line) else { return XCTFail("not json") }
        XCTAssertEqual(event.level, "error")
        XCTAssertEqual(event.success, false)
        XCTAssertEqual(event.time, "2026-10-26T03:26:57+08:00")
        XCTAssertTrue(event.isError)
        XCTAssertEqual(event.error, "either the app ID or the bundle identifier must be specified")
    }

    func testSearchLineDecodesApps() throws {
        let line = #"{"level":"info","count":1,"apps":[{"id":333903271,"bundleID":"com.atebits.Tweetie2","name":"X（前身为Twitter）","version":"12.37","price":0,"platforms":["iphone","ipad"]}],"time":"2026-10-26T03:00:00+08:00"}"#
        let apps = try SearchService.parse(result([line]))
        XCTAssertEqual(apps, [AppSummary(id: 333903271, bundleID: "com.atebits.Tweetie2", name: "X（前身为Twitter）",
                                         version: "12.37", price: 0, platforms: ["iphone", "ipad"])])
        XCTAssertTrue(apps[0].isFree)
    }

    func testSearchToleratesMissingFieldsAndEmptyResult() throws {
        let line = #"{"level":"info","count":1,"apps":[{"id":42,"name":"Foo"}]}"#
        let apps = try SearchService.parse(result([line]))
        XCTAssertEqual(apps.first?.bundleID, "")
        XCTAssertEqual(apps.first?.platforms, [])
        XCTAssertEqual(try SearchService.parse(result([#"{"level":"info","count":0}"#])), [])
        XCTAssertThrowsError(try SearchService.parse(result(["garbage"])))
    }

    func testNonJSONLinesAreText() {
        XCTAssertEqual(IpatoolLineParser.parse("downloading  21% |██  | (12/45 MB, 1.2 MB/s)"),
                       .text("downloading  21% |██  | (12/45 MB, 1.2 MB/s)"))
        XCTAssertEqual(IpatoolLineParser.parse("{not json}"), .text("{not json}"))
        XCTAssertEqual(IpatoolLineParser.parse("ipatool version 2.7.0"), .text("ipatool version 2.7.0"))
    }

    func testVersionParsing() {
        XCTAssertEqual(IpatoolLocator.parseVersion("ipatool version 2.7.0"), "2.7.0")
        XCTAssertNil(IpatoolLocator.parseVersion("nothing"))
    }

    func testListVersionsAndMetadataParsing() throws {
        let list = #"{"level":"info","externalVersionIdentifiers":["853456789","853999999",854000001],"bundleID":"com.example.app","success":true}"#
        let (ids, bundle) = try VersionService.parseVersionList(result([list]))
        XCTAssertEqual(ids, ["853456789", "853999999", "854000001"])
        XCTAssertEqual(bundle, "com.example.app")
        let empty = #"{"level":"info","externalVersionIdentifiers":[],"bundleID":"","success":true}"#
        XCTAssertNil(try VersionService.parseVersionList(result([empty])).1)

        let meta = #"{"level":"info","externalVersionID":"853999999","displayVersion":"3.8.5","releaseDate":"2026-09-01T08:00:00Z","success":true}"#
        let m = try VersionService.parseMetadata(result([meta]), fallbackID: "x")
        XCTAssertEqual(m.externalVersionID, "853999999")
        XCTAssertEqual(m.displayVersion, "3.8.5")
        XCTAssertEqual(m.releaseDate, Date(timeIntervalSince1970: 1_788_249_600))
    }
}

final class LoginPromptDetectorTests: XCTestCase {
    func testDetectsAllPromptsInOrder() {
        var d = LoginPromptDetector()
        XCTAssertEqual(d.feed("enter Apple ID (email address or phone number): "), [.appleID])
        XCTAssertEqual(d.feed("enter password: "), [.password])
        XCTAssertEqual(d.feed("****\r\n"), [])
        XCTAssertEqual(d.feed("enter 2FA code: "), [.twoFactorCode])
    }

    func testPromptSplitAcrossChunksAndWithANSI() {
        var d = LoginPromptDetector()
        XCTAssertEqual(d.feed("\u{1B}[0menter 2F"), [])
        XCTAssertEqual(d.feed("A code: "), [.twoFactorCode])
        XCTAssertEqual(d.feed("enter 2FA code: "), [.twoFactorCode], "再次出现时仍能识别")
    }

    func testMultiplePromptsInOneChunkAndNoFalsePositive() {
        var d = LoginPromptDetector()
        XCTAssertEqual(d.feed("enter Apple ID: x\nenter password: "), [.appleID, .password])
        XCTAssertEqual(d.feed(#"{"level":"info","message":"2FA code is required; run the command again"}"#), [])
        XCTAssertTrue(LoginPromptDetector.containsPrompt("enter password: ******"))
        XCTAssertFalse(LoginPromptDetector.containsPrompt("downloading 5%"))
    }
}

final class ProgressParserTests: XCTestCase {
    func testTypicalLine() throws {
        let p = try XCTUnwrap(ProgressParser.parse("downloading  21% [====>     ] (12/45 MB, 1.2 MB/s)"))
        XCTAssertEqual(p.fraction!, 0.21, accuracy: 1e-9)
        XCTAssertEqual(p.bytes, 12_000_000)
        XCTAssertEqual(p.total, 45_000_000)
        XCTAssertEqual(p.bytesPerSecond!, 1_200_000, accuracy: 1e-6)
        XCTAssertEqual(p.source, .progressBar)
    }

    func testZeroAndHundredPercent() throws {
        let zero = try XCTUnwrap(ProgressParser.parse("downloading   0% |          | (0 B/156 MB)"))
        XCTAssertEqual(zero.fraction, 0)
        XCTAssertEqual(zero.bytes, 0)
        XCTAssertEqual(zero.total, 156_000_000)
        XCTAssertNil(zero.bytesPerSecond)

        let full = try XCTUnwrap(ProgressParser.parse("downloading 100% |██████████| (156/156 MB, 8.4 MB/s)"))
        XCTAssertEqual(full.fraction, 1)
        XCTAssertEqual(full.bytes, full.total)
    }

    func testGigabytesMixedUnitsAndMissingSpeed() throws {
        let p = try XCTUnwrap(ProgressParser.parse("downloading  48% |████      | (1.2 GB/2.5 GB)"))
        XCTAssertEqual(p.bytes, 1_200_000_000)
        XCTAssertEqual(p.total, 2_500_000_000)
        XCTAssertNil(p.bytesPerSecond)

        let mixed = try XCTUnwrap(ProgressParser.parse("downloading  3% (512 kB/1.5 GB, 640 kB/s)"))
        XCTAssertEqual(mixed.bytes, 512_000)
        XCTAssertEqual(mixed.total, 1_500_000_000)
        XCTAssertEqual(mixed.bytesPerSecond!, 640_000, accuracy: 1e-6)
    }

    func testBinaryUnitsANSIAndNoPercent() throws {
        let p = try XCTUnwrap(ProgressParser.parse("\u{1B}[2Kdownloading (1/4 MiB, 512 KiB/s)"))
        XCTAssertEqual(p.bytes, 1_048_576)
        XCTAssertEqual(p.total, 4_194_304)
        XCTAssertEqual(p.fraction!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(p.bytesPerSecond!, 524_288, accuracy: 1e-6)
    }

    func testNonProgressLinesReturnNil() {
        XCTAssertNil(ProgressParser.parse("preparing authentication; the first login may take a few minutes"))
        XCTAssertNil(ProgressParser.parse(""))
        XCTAssertNil(ProgressParser.parse("downloading"))
    }

    func testTempFileFallbackTracker() {
        let tracker = ProgressTracker()
        XCTAssertTrue(tracker.shouldPoll(staleAfter: 2))
        tracker.record(DownloadProgress(fraction: 0.1, bytes: 10, total: 1000, bytesPerSecond: nil, source: .progressBar))
        XCTAssertFalse(tracker.shouldPoll(staleAfter: 2))
        let t0 = Date()
        let first = tracker.fromFileSize(200, now: t0)
        XCTAssertEqual(first?.fraction, 0.2)
        XCTAssertNil(first?.bytesPerSecond)
        let second = tracker.fromFileSize(400, now: t0.addingTimeInterval(2))
        XCTAssertEqual(second?.bytesPerSecond, 100)
        XCTAssertEqual(second?.source, .tempFile)
    }
}
