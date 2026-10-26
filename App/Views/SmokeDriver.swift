#if DEBUG
import AppKit
import SwiftUI
import IPADepotCore

/// 仅 Debug 构建：界面冒烟脚本。用启动参数 `-IPADepotSmokeOutput <目录>` 触发，
/// 自动走一遍「准备页 → 搜索 → 历史版本 → 下载 / 记录 / 设置」并把本 App 自己的窗口渲染成 PNG。
/// 不执行登录、登出、领取许可与下载。
@MainActor
enum SmokeDriver {
    static var isActive: Bool { UserDefaults.standard.string(forKey: "IPADepotSmokeOutput") != nil }

    static func runIfRequested(_ model: AppModel) async {
        // 启动参数 `-key value` 进入 UserDefaults 的参数域；这里只读不写。
        guard let output = UserDefaults.standard.string(forKey: "IPADepotSmokeOutput") else { return }
        let dir = URL(fileURLWithPath: output, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ text: String) {
            log.append("[\(Date().formatted(date: .omitted, time: .standard))] \(text)")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("smoke-log.txt"), atomically: true, encoding: .utf8)
        }

        note("brand font loaded: \(NSFont(name: BrandFont.postScriptName, size: 12) != nil)")
        if let mode = UserDefaults.standard.string(forKey: "IPADepotSmokeMode") {
            await runPhase3(mode: mode, model: model, dir: dir, note: note)
            note("done")
            NSApp.terminate(nil)
            return
        }
        await wait(timeout: 60) { model.accountState != .checking }
        let signedIn = model.account != nil
        note("account: \(signedIn ? "signedIn（姓名与邮箱不记录）" : String(describing: model.accountState))")

        // 未登录界面（只切换显示状态，不登出）
        model.debugShowSignedOutState()
        await sleep(1.0)
        capture("00-signed-out", dir: dir)
        await model.refreshAccount()
        await sleep(1.0)
        capture("01-launch", dir: dir)

        // 登录准备页（只打开，不登录）
        model.beginLogin()
        await sleep(1.2)
        capture("02-login-intro", dir: dir)
        model.login?.continueFromIntro()
        await sleep(0.8)
        capture("03-login-credentials", dir: dir)
        model.dismissLogin()
        await sleep(0.8)

        // 搜索「音乐」
        model.page = .search
        model.search.query = "音乐"
        model.search.limit = 25
        await model.search.search()
        note("search 音乐 → phase=\(model.search.phase) rows=\(model.search.rows.count)")
        await wait(timeout: 20) { model.artwork.images.count >= min(6, model.search.rows.count) }
        await sleep(1.0)
        capture("04-search-results", dir: dir)

        // 历史版本：1606306441（谜底黑胶）
        let targetID: Int64 = 1606306441
        var row = model.search.rows.first { $0.id == targetID }
        if row == nil {
            model.search.query = "谜底黑胶"
            await model.search.search()
            row = model.search.rows.first { $0.id == targetID }
            note("search 谜底黑胶 → rows=\(model.search.rows.count) found=\(row != nil)")
        }
        let target = row ?? AppRowModel(app: AppSummary(id: targetID, bundleID: "", name: "谜底黑胶", version: "",
                                                         price: 0, platforms: ["iphone"]), platform: .iphone)
        model.searchPath = [target]
        let versions = model.versionsModel(for: target)
        await wait(timeout: 120) { versions.phase != .loading }
        note("versions phase=\(versions.phase) count=\(versions.rows.count)")
        await wait(timeout: 180) { versions.loadedCount >= min(12, versions.rows.count) }
        await sleep(1.0)
        note("versions loaded=\(versions.loadedCount) batches=\(versions.batchLog.count) first=\(versions.rows.prefix(3).map { "\($0.id)=\($0.metadata?.displayVersion ?? "-")" })")
        capture("05-versions", dir: dir)

        model.page = .downloads
        await sleep(1.0)
        capture("06-downloads", dir: dir)
        model.page = .history
        await sleep(1.0)
        capture("07-history", dir: dir)
        model.page = .settings
        await wait(timeout: 20) { model.settings.ipatoolVersion != nil || model.settings.ipatoolVersionError != nil }
        await sleep(1.0)
        capture("08-settings", dir: dir)
        note("ipatool version=\(model.settings.ipatoolVersion ?? model.settings.ipatoolVersionError ?? "-")")
        note("done")
        NSApp.terminate(nil)
    }

    /// 阶段三冒烟（`-IPADepotSmokeMode <mode>`）：
    /// - `firstLaunch`：首次启动标志为假 → 未登录、搜索先引导登录、准备页、设置页 ipatool 版本；
    /// - `signedIn`：配合启动参数 `-hasCompletedFirstLogin YES`（参数域，不写偏好）→ 启动查询账号；
    /// - `queueAdd`：加入两个下载任务（需配合只 sleep 的假 ipatool，不真正下载），然后退出；
    /// - `queueRestore`：重新启动后查看恢复的队列；
    /// - `p4LoginIntro`：只打开登录准备页截图（不登录）；
    /// - `p4Fail`：加入一个下载任务，配合「第一次 download 即失败」的假 ipatool，查看失败态，然后退出；
    /// - `p4Restore`：重启后查看恢复的失败任务（暂停 + 上次失败原因），点重试（假 ipatool 第二次只 sleep），然后退出。
    private static func runPhase3(mode: String, model: AppModel, dir: URL, note: (String) -> Void) async {
        func describe(_ state: AppModel.AccountState) -> String {
            switch state {
            case .checking: return "checking"
            case .signedOut: return "signedOut"
            case .signedIn: return "signedIn（姓名与邮箱不记录）"
            case .unknown(let e): return "unknown(\(e.message))"
            }
        }
        note("mode=\(mode) hasCompletedFirstLogin=\(model.hasCompletedFirstLogin)")
        switch mode {
        case "firstLaunch":
            await sleep(1.5)
            note("account after bootstrap: \(describe(model.accountState))")
            capture("p3-01-first-launch", dir: dir)
            model.page = .search
            model.search.query = "音乐"
            await model.search.search()
            note("search 音乐 → phase=\(model.search.phase)")
            await sleep(0.8)
            capture("p3-02-first-launch-search", dir: dir)
            model.beginLogin()
            await sleep(1.2)
            capture("p3-03-login-intro", dir: dir)
            model.dismissLogin()
            await sleep(0.8)
            model.page = .settings
            await wait(timeout: 20) { model.settings.ipatoolVersion != nil || model.settings.ipatoolVersionError != nil }
            await sleep(1.0)
            note("ipatool version=\(model.settings.ipatoolVersion ?? model.settings.ipatoolVersionError ?? "-")")
            capture("p3-04-settings", dir: dir)
        case "signedIn":
            await wait(timeout: 60) { model.accountState != .checking }
            note("account after bootstrap: \(describe(model.accountState))")
            await sleep(1.0)
            capture("p3-05-signed-in", dir: dir)
        case "queueAdd":
            let first = AppSummary(id: 1606306441, bundleID: "", name: "谜底黑胶", version: "3.8.5", price: 0, platforms: ["iphone"])
            let second = AppSummary(id: 414603431, bundleID: "com.tencent.QQMusic", name: "QQ音乐", version: "20.9.6",
                                    price: 0, platforms: ["iphone"])
            await model.downloads.enqueue(DownloadContext(app: first, platform: .iphone, externalVersionID: "893783327",
                                                          versionLabel: "3.8.5"))
            await model.downloads.enqueue(DownloadContext(app: second, platform: .iphone, externalVersionID: nil,
                                                          versionLabel: nil))
            model.page = .downloads
            await wait(timeout: 10) { model.downloads.activeRows.count == 2 }
            await sleep(2.0)
            note("rows before quit: \(model.downloads.activeRows.map { "\($0.context.name)=\($0.statusText)" })")
            capture("p3-06-queue-added", dir: dir)
        case "queueRestore":
            model.page = .downloads
            await wait(timeout: 10) { !model.downloads.activeRows.isEmpty }
            await sleep(2.0)
            note("rows after relaunch: \(model.downloads.activeRows.map { "\($0.context.name)=\($0.statusText) canResume=\($0.canResume)" })")
            capture("p3-07-queue-restored", dir: dir)
        case "p4LoginIntro":
            model.beginLogin()
            await sleep(1.5)
            capture("p4-01-login-intro", dir: dir)
            model.dismissLogin()
            await sleep(0.5)
        case "p4Fail":
            let app = AppSummary(id: 1606306441, bundleID: "", name: "谜底黑胶", version: "3.8.5", price: 0, platforms: ["iphone"])
            await model.downloads.enqueue(DownloadContext(app: app, platform: .iphone, externalVersionID: "893783327",
                                                          versionLabel: "3.8.5"))
            model.page = .downloads
            await wait(timeout: 20) { model.downloads.activeRows.first?.isFailed == true }
            await sleep(1.5)
            note("rows after failure: \(describeRows(model))")
            capture("p4-02-failed", dir: dir)
        case "p4Restore":
            model.page = .downloads
            await wait(timeout: 10) { !model.downloads.activeRows.isEmpty }
            await sleep(1.5)
            note("rows after relaunch: \(describeRows(model))")
            capture("p4-03-restored", dir: dir)
            if let id = model.downloads.activeRows.first?.id {
                model.downloads.resume(id)
                await wait(timeout: 10) { model.downloads.activeRows.first?.status == .running }
                await sleep(2.0)
                note("rows after retry: \(describeRows(model))")
                capture("p4-04-retrying", dir: dir)
            }
        default:
            note("unknown mode")
        }
    }

    private static func describeRows(_ model: AppModel) -> String {
        model.downloads.activeRows.map {
            "\($0.context.name)=\($0.statusText) retry=\($0.isRetry) raw=\($0.errorRaw ?? "-") output=\($0.output.lastPathComponent)"
        }.joined(separator: " | ")
    }

    private static func wait(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await sleep(0.25)
        }
    }

    private static func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// 窗口服务器合成后的本窗口图像（含侧栏材质）。函数在新 SDK 里不可直接调用，这里按符号动态查找；拿不到就返回 nil。
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        // kCGWindowListOptionIncludingWindow = 8；kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution = 1 | 8
        return function(.null, 8, UInt32(window.windowNumber), 9)?.takeRetainedValue()
    }

    /// 把本 App 的可见窗口（含 sheet）存成 PNG。只取自己的窗口，不截全屏。
    static func capture(_ name: String, dir: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 200 }
        for window in windows {
            let suffix = window.sheetParent != nil ? "-sheet" : ""
            let file = dir.appendingPathComponent("\(name)\(suffix).png")
            if let image = windowServerImage(window), image.width > 1,
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: file)
                continue
            }
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            let rect = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { continue }
            view.cacheDisplay(in: rect, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: file)
        }
    }
}
#endif
