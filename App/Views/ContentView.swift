import SwiftUI
import IPADepotCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSetupError = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .sheet(isPresented: Binding(get: { model.login != nil },
                                    set: { if !$0 { model.dismissLogin() } })) {
            if let login = model.login {
                LoginSheet(login: login)
            }
        }
        .alert(model.downloads.licensePrompt?.context.name ?? "",
               isPresented: Binding(get: { model.downloads.licensePrompt != nil },
                                    set: { if !$0 { model.downloads.dismissLicense() } }),
               presenting: model.downloads.licensePrompt) { prompt in
            if prompt.isFree {
                Button("领取并下载") { Task { await model.downloads.confirmLicense(prompt) } }
                Button("取消", role: .cancel) { model.downloads.dismissLicense() }
            } else {
                Button("好", role: .cancel) { model.downloads.dismissLicense() }
            }
        } message: { prompt in
            if prompt.isFree {
                Text("该 App 尚未加入你的账号，是否领取免费许可后下载？")
            } else {
                Text("这是付费 App，须先在 App Store 购买后才能下载。")
            }
        }
        .overlay { AccountSwitchOverlay() }
        .animation(.easeInOut(duration: 0.15), value: model.accounts.isOverlayVisible)
        .sheet(isPresented: Binding(get: { model.accounts.showingManager },
                                    set: { model.accounts.showingManager = $0 })) {
            AccountManagerSheet()
        }
        .sheet(item: Binding(get: { model.accounts.passwordPrompt }, set: { model.accounts.passwordPrompt = $0 })) { prompt in
            AccountPasswordSheet(prompt: prompt)
        }
        .sheet(item: Binding(get: { model.accounts.regionPrompt }, set: { model.accounts.regionPrompt = $0 })) { account in
            AccountRegionPromptSheet(account: account)
        }
        .alert(model.accounts.failure?.title ?? "",
               isPresented: Binding(get: { model.accounts.failure != nil }, set: { if !$0 { model.accounts.failure = nil } }),
               presenting: model.accounts.failure) { _ in
            Button("好", role: .cancel) {}
        } message: { failure in
            Text(failure.presentation.raw.isEmpty ? failure.presentation.message
                 : "\(failure.presentation.message)\n\n\(failure.presentation.raw)")
        }
        .errorAlert($model.logoutError, title: "登出失败")
        .errorAlert(Binding(get: { model.downloads.enqueueError }, set: { model.downloads.enqueueError = $0 }),
                    title: "无法开始下载")
        .alert("找不到 ipatool", isPresented: $showingSetupError, presenting: model.setupError) { _ in
            Button("好", role: .cancel) {}
        } message: { error in
            Text(error.message)
        }
        .task {
            if model.setupError != nil { showingSetupError = true }
            await model.bootstrap()
            #if DEBUG
            await SmokeDriver.runIfRequested(model)
            #endif
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.page ?? .search {
        case .search: SearchView()
        case .downloads: DownloadsView()
        case .history: HistoryView()
        case .settings: SettingsView()
        }
    }
}

// MARK: - 侧栏

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.page) {
            Label("搜索", systemImage: "magnifyingglass")
                .tag(AppModel.Page.search)
            Label("下载", systemImage: "arrow.down.circle")
                .badge(model.downloads.activeCount)
                .tag(AppModel.Page.downloads)
            Label("记录", systemImage: "clock")
                .tag(AppModel.Page.history)
            Label("设置", systemImage: "gearshape")
                .tag(AppModel.Page.settings)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AccountFooter()
        }
    }
}

struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingLogout = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("确定要登出当前账号吗？", isPresented: $confirmingLogout) {
            Button("登出", role: .destructive) { Task { await model.logout() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("登出会删除 ipatool 保存在钥匙串中的登录信息；账号仍保留在列表里，可随时切换回来。下载记录不受影响。")
        }
    }

    /// Debug 冒烟截图时遮住账号信息，避免截图含个人信息（冒烟用的假账号 `@example.test` 除外）。
    static func displayed(_ account: AccountInfo) -> AccountInfo {
        #if DEBUG
        if SmokeDriver.isActive && !account.email.hasSuffix("@example.test") {
            return AccountInfo(name: "Apple ID", email: "•••@•••")
        }
        #endif
        return account
    }

    static func displayed(account: AccountRecord) -> AccountRecord {
        #if DEBUG
        if SmokeDriver.isActive && !account.email.hasSuffix("@example.test") {
            var masked = account
            masked.email = "•••@•••"
            masked.displayName = "Apple ID"
            return masked
        }
        #endif
        return account
    }

    @ViewBuilder
    private var content: some View {
        switch model.accountState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查账号…").font(.callout).foregroundStyle(.secondary)
            }
        case .signedIn(let signedIn):
            let account = Self.displayed(signedIn)
            Menu {
                AccountMenuItems(includeSignOut: true) { confirmingLogout = true }
            } label: {
                HStack(spacing: 6) {
                    AccountIdentityView(region: model.accounts.active?.regionLabel, name: account.name, email: account.email)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(model.accounts.isSwitching)
            .help("切换账号")
        case .signedOut:
            VStack(alignment: .leading, spacing: 8) {
                Text("尚未登录 Apple ID").font(.callout).foregroundStyle(.secondary)
                if model.accounts.accounts.isEmpty {
                    Button {
                        model.beginLogin()
                    } label: {
                        Text("登录").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else {
                    Menu {
                        AccountMenuItems(includeSignOut: false) {}
                    } label: {
                        Text("选择账号登录").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.accounts.isSwitching)
                }
            }
        case .unknown(let error):
            VStack(alignment: .leading, spacing: 6) {
                Label("无法获取账号状态", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(error.message)
                HStack {
                    Button("重试") { Task { await model.refreshAccount() } }
                    Button("登录") { model.beginLogin() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 通用组件

/// 错误说明：中文文案 + 可折叠的原始错误。
struct ErrorDetailView: View {
    let error: ErrorPresentation
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error.message)
                .fixedSize(horizontal: false, vertical: true)
            if !error.raw.isEmpty {
                DisclosureGroup("查看原始错误", isExpanded: $expanded) {
                    Text(error.raw)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .font(.callout)
            }
        }
    }
}

/// 图标：iTunes Lookup 取到的 artwork，取不到时显示占位符。
struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let appID: Int64
    var size: CGFloat = 48

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image = model.artwork.images[appID] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                shape.fill(.quaternary)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.42, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .task(id: appID) { await model.artwork.request(appID) }
    }
}

/// 平台标签。
struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

extension View {
    /// 以 `ErrorPresentation` 驱动的错误提示框。
    func errorAlert(_ error: Binding<ErrorPresentation?>, title: LocalizedStringKey) -> some View {
        alert(title, isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } }),
              presenting: error.wrappedValue) { _ in
            Button("好", role: .cancel) {}
        } message: { presentation in
            Text(presentation.raw.isEmpty ? presentation.message : "\(presentation.message)\n\n\(presentation.raw)")
        }
    }
}

/// 在访达中显示。
enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
