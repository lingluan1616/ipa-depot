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
