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
    /// - `p4Restore`：重启后查看恢复的失败任务（暂停 + 上次失败原因），点重试（假 ipatool 第二次只 sleep），然后退出；
    /// - `p5Accounts`：多账号完整流程（见 `runPhase5`）。
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
        case "p5Accounts":
            await runPhase5(model: model, dir: dir, note: note)
        case "p5Migrate":
            // 配合 `-hasCompletedFirstLogin YES`（参数域）与已「登录」的假 ipatool：0.1.0 升级迁移 → 自动建账号并请选地区
            await wait(timeout: 20) { model.accountState != .checking }
            await sleep(1.2)
            note("migrate: account=\(model.account?.email ?? "-") accounts=\(model.accounts.accounts.map { "\($0.email):\($0.regionLabel.rawValue):\($0.passwordState.rawValue)" }) prompt=\(model.accounts.regionPrompt?.email ?? "-")")
            capture("p5-13-migration-region-prompt", dir: dir)
            model.accounts.regionPrompt = nil // 有 sheet 时系统不会退出 App
            await sleep(0.8)
        case "p6Browse":
            await runPhase6(model: model, dir: dir, note: note)
        default:
            note("unknown mode")
        }
    }

    /// 阶段五冒烟（配合假 ipatool，不碰真实钥匙串与 ~/.ipatool）：添加日本账号 → 搜索 → 添加美国账号（2FA）→ 搜索结果随账号变化
    /// → 美国账号的下载失败后切回日本 → 重试该任务时队列自动切换到美国（Cookie 过期需 2FA，遮罩输入验证码）→ 下载开始。
    private static func runPhase5(model: AppModel, dir: URL, note: (String) -> Void) async {
        func searchNow(_ term: String) async {
            model.page = .search
            model.search.query = term
            await model.search.search()
        }
        func accountsLine() -> String {
            model.accounts.accounts.map { "\($0.regionLabel.rawValue):\($0.email):\($0.passwordState.rawValue)\($0.id == model.accounts.active?.id ? "*" : "")" }
                .joined(separator: ", ")
        }
        await sleep(1.0)
        note("start: account=\(model.accountState) accounts=[\(accountsLine())]")
        capture("p5-01-signed-out", dir: dir)

        // 1. 首次登录 = 添加第一个账号（日本）
        model.beginLogin()
        await sleep(0.8)
        guard let first = model.login else { note("no login sheet"); return }
        first.continueFromIntro()
        first.appleID = "jp@example.test"
        first.password = "jp-pass"
        first.region = .japan
        await sleep(0.5)
        capture("p5-02-add-first-account", dir: dir)
        await first.submitCredentials()
        await wait(timeout: 20) { model.login == nil }
        await sleep(0.8)
        note("after jp login: account=\(model.account?.email ?? "-") accounts=[\(accountsLine())]")

        await searchNow("app")
        await sleep(0.8)
        note("search as jp → \(model.search.rows.map(\.name))")
        capture("p5-03-search-japan", dir: dir)

        // 2. 添加美国账号：先保存并退出日本账号，美国账号首次登录需要验证码
        model.beginLogin()
        await sleep(0.8)
        guard let second = model.login else { note("no login sheet 2"); return }
        note("add sheet mode=\(second.mode) step=\(second.step)")
        second.appleID = "us@example.test"
        second.password = "us-pass"
        second.region = .unitedStates
        let submitTask = Task { await second.submitCredentials() }
        await wait(timeout: 20) { second.step == .twoFactor }
        await sleep(0.6)
        capture("p5-04-add-us-2fa", dir: dir)
        second.code = "123456"
        second.submitCode()
        await submitTask.value
        await wait(timeout: 20) { model.login == nil }
        await sleep(0.8)
        note("after us add: account=\(model.account?.email ?? "-") search.phase=\(model.search.phase) accounts=[\(accountsLine())]")
        capture("p5-05-switched-to-us-notice", dir: dir)

        await searchNow("app")
        await sleep(0.8)
        note("search as us → \(model.search.rows.map(\.name))")
        capture("p5-06-search-us", dir: dir)

        // 3. 美国账号下一个任务（假 ipatool 第一次下载失败），任务留在列表
        try? Data().write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["IPADEPOT_SMOKE_STATE"] ?? "/nonexistent")
            .appendingPathComponent("fail-once"))
        if let row = model.search.rows.first {
            await model.downloads.enqueue(DownloadContext(app: row.app, platform: .iphone, externalVersionID: nil, versionLabel: nil))
        }
        await wait(timeout: 15) { model.downloads.activeRows.first?.isFailed == true }
        note("us task: \(describeRows(model))")

        // 4. 管理账号页
        model.accounts.showingManager = true
        await sleep(1.0)
        capture("p5-07-manage-accounts", dir: dir)
        model.accounts.showingManager = false
        await sleep(0.8)

        // 5. 手动切换回日本账号（Cookie 已保存，不需要验证码），遮罩显示进度
        if let jp = model.accounts.accounts.first(where: { $0.email == "jp@example.test" }) {
            model.page = .search
            model.switchAccount(to: jp)
            await wait(timeout: 10) { model.accounts.isOverlayVisible }
            await sleep(0.5)
            note("overlay: \(model.accounts.switchProgress.map(AccountsViewModel.statusText) ?? "-")")
            capture("p5-08-switch-overlay", dir: dir)
            await wait(timeout: 20) { model.account?.email == jp.email && !model.accounts.isSwitching }
            await sleep(0.8)
            note("after switch to jp: search.phase=\(model.search.phase)")
            capture("p5-09-switched-to-jp", dir: dir)
        }

        // 6. 模拟美国账号的受信任 Cookie 过期，然后重试美国账号的任务 → 队列自动切换（遮罩里输入验证码）→ 开始下载
        if let us = model.accounts.accounts.first(where: { $0.email == "us@example.test" }) {
            let archive = model.services.paths.accountsDirectory.appendingPathComponent(us.id.uuidString).appendingPathComponent("cookies")
            try? FileManager.default.removeItem(at: archive)
        }
        model.page = .downloads
        if let id = model.downloads.activeRows.first?.id { model.downloads.resume(id) }
        await wait(timeout: 20) { model.accounts.switchProgress?.phase == .needsTwoFactor }
        await sleep(0.6)
        note("queue auto-switch: \(describeRows(model)) overlay=\(model.accounts.switchProgress.map(AccountsViewModel.statusText) ?? "-")")
        capture("p5-10-queue-switch-2fa", dir: dir)
        model.accounts.code = "123456"
        model.accounts.submitCode()
        await wait(timeout: 20) { model.downloads.activeRows.first?.status == .running }
        await sleep(1.5)
        note("after auto-switch: account=\(model.account?.email ?? "-") rows=\(describeRows(model))")
        capture("p5-11-downloading-as-us", dir: dir)

        model.page = .search
        await sleep(0.8)
        capture("p5-12-search-after-auto-switch", dir: dir)
        note("final accounts=[\(accountsLine())]")
    }

    /// 阶段六冒烟（假 ipatool；公开目录走真实的 itunes.apple.com，公开接口、无需登录）：
    /// 添加日本账号 → 浏览地区切到「美国」搜 vinyl（带「公开目录」标签）→ 点历史版本触发「没有 美国 地区的账号」
    /// → 添加账号（地区预选美国，需 2FA）后自动继续进入历史版本 → 切回日本 → 再点历史版本触发自动切换（遮罩）
    /// → 从公开目录下载最新版，队列显示地区与「公开目录」标签。结束时删掉本次写进偏好的浏览地区。
    private static func runPhase6(model: AppModel, dir: URL, note: (String) -> Void) async {
        let hadBrowseKey = UserDefaults.standard.persistentDomain(forName: "app.ipadepot.mac")?[BrowseRegion.defaultsKey] != nil
        defer {
            if !hadBrowseKey { UserDefaults.standard.removeObject(forKey: BrowseRegion.defaultsKey) }
        }
        func accountsLine() -> String {
            model.accounts.accounts.map { "\($0.regionLabel.rawValue):\($0.email)\($0.id == model.accounts.active?.id ? "*" : "")" }
                .joined(separator: ", ")
        }
        await sleep(1.0)
        // 1. 添加日本账号
        model.beginLogin()
        await sleep(0.8)
        guard let first = model.login else { note("no login sheet"); return }
        first.continueFromIntro()
        first.appleID = "jp@example.test"
        first.password = "jp-pass"
        first.region = .japan
        await first.submitCredentials()
        await wait(timeout: 20) { model.login == nil }
        await sleep(0.5)
        note("after jp login: accounts=[\(accountsLine())]")

        // 2. 浏览地区 = 美国，搜 vinyl（真实公开目录；网络慢时重试一次）
        model.page = .search
        model.search.query = "vinyl"
        model.search.setBrowseRegion(.region(.unitedStates, customCode: nil))
        await wait(timeout: 25) { model.search.phase != .loading && model.search.phase != .idle }
        if case .failed(let error) = model.search.phase {
            note("catalog search failed once: \(error.message) \(error.raw)；重试")
            model.search.submit()
            await sleep(0.5)
            await wait(timeout: 25) { model.search.phase != .loading }
        }
        note("browse us → phase=\(model.search.phase) rows=\(model.search.rows.count) public=\(model.search.rows.filter(\.isPublicCatalog).count) first=\(model.search.rows.prefix(3).map { "\($0.name)(\($0.id))" })")
        await wait(timeout: 15) { model.artwork.images.count >= min(5, model.search.rows.count) }
        await sleep(1.0)
        capture("p6-01-browse-us-results", dir: dir)
        guard let row = model.search.rows.first else { note("no catalog rows"); return }

        // 3. 没有美国账号 → 提示
        model.perform(.versions(row))
        await sleep(1.0)
        note("missing prompt: \(model.missingRegionPrompt.map { "\($0.countryCode) \($0.regionTitle)" } ?? "-")")
        capture("p6-02-no-us-account-alert", dir: dir)
        guard let prompt = model.missingRegionPrompt else { return }

        // 4. 添加账号…（地区预选美国）→ 2FA → 成功后自动进入历史版本
        model.addAccount(for: prompt)
        await sleep(1.0)
        guard let add = model.login else { note("no add sheet"); return }
        note("add sheet region=\(add.region.rawValue) mode=\(add.mode)")
        add.appleID = "us@example.test"
        add.password = "us-pass"
        await sleep(0.4)
        capture("p6-03-add-us-preselected", dir: dir)
        let submit = Task { await add.submitCredentials() }
        await wait(timeout: 20) { add.step == .twoFactor }
        await sleep(0.6)
        capture("p6-04-2fa-copy", dir: dir)
        add.code = "123456"
        add.submitCode()
        await submit.value
        await wait(timeout: 20) { model.login == nil && model.searchPath.last == row }
        await sleep(1.5)
        note("after add: active=\(model.accounts.active?.email ?? "-") path=\(model.searchPath.map(\.name)) accounts=[\(accountsLine())]")
        capture("p6-05-continued-to-versions", dir: dir)

        // 5. 切回日本，再点历史版本 → 自动切换到美国（遮罩）
        model.searchPath = []
        if let jp = model.accounts.accounts.first(where: { $0.email == "jp@example.test" }) {
            model.switchAccount(to: jp)
            await wait(timeout: 20) { model.accounts.active?.id == jp.id && !model.accounts.isSwitching }
        }
        await sleep(0.8)
        note("back to jp: active=\(model.accounts.active?.email ?? "-") rows still=\(model.search.rows.count)")
        capture("p6-06-back-to-jp-results-kept", dir: dir)
        model.perform(.versions(row))
        await wait(timeout: 10) { model.accounts.isOverlayVisible }
        await sleep(0.3)
        note("overlay: \(model.accounts.switchProgress.map(AccountsViewModel.statusText) ?? "-")")
        capture("p6-07-auto-switch-overlay", dir: dir)
        await wait(timeout: 20) { !model.accounts.isSwitching && model.searchPath.last == row }
        await sleep(1.5)
        note("after auto-switch: active=\(model.accounts.active?.email ?? "-") path=\(model.searchPath.map(\.name))")
        capture("p6-08-versions-after-auto-switch", dir: dir)

        // 6. 从公开目录下载最新版（当前账号已是美国）→ 队列标签
        model.searchPath = []
        model.perform(.download(row))
        model.page = .downloads
        await wait(timeout: 10) { !model.downloads.activeRows.isEmpty }
        await sleep(1.5)
        note("queue: \(model.downloads.activeRows.map { "\($0.context.name) region=\($0.regionTitle ?? "-") public=\($0.isPublicCatalog) \($0.statusText)" })")
        capture("p6-09-queue-public-catalog-tag", dir: dir)
        if let id = model.downloads.activeRows.first?.id { model.downloads.cancel(id) }
        await sleep(1.0)
        model.page = .search
        model.search.setBrowseRegion(.followAccount)
        note("final accounts=[\(accountsLine())]")
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
