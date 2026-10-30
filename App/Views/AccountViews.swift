import SwiftUI
import IPADepotCore

// MARK: - 侧栏底部：账号切换菜单

/// 当前账号的显示（地区标签 + 显示名 + 邮箱）。
struct AccountIdentityView: View {
    let region: String?
    let name: String
    let email: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if let region { TagView(text: region) }
                    Text(name.isEmpty ? String(localized: "已登录") : name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// 账号菜单的内容：其他账号（点击切换）、添加 / 管理账号、登出。
struct AccountMenuItems: View {
    @Environment(AppModel.self) private var model
    var includeSignOut: Bool
    let onSignOut: () -> Void

    var body: some View {
        let accounts = model.accounts
        let others = model.account == nil ? accounts.accounts : accounts.others
        if !others.isEmpty {
            Section(model.account == nil ? "选择账号登录" : "切换到") {
                ForEach(others) { account in
                    Button {
                        model.switchAccount(to: AccountFooter.displayed(account: account))
                    } label: {
                        Text(verbatim: AccountFooter.displayed(account: account).menuTitle)
                    }
                    .disabled(!model.canSwitchAccounts)
                }
            }
            if model.downloads.hasActiveDownload {
                Text("有下载正在进行，暂停后才能切换账号")
            }
        }
        Divider()
        Button("添加账号…") { model.beginLogin() }
            .disabled(model.accounts.isSwitching)
        Button("管理账号…") { model.accounts.showingManager = true }
        if includeSignOut {
            Divider()
            Button("登出当前账号…", action: onSignOut)
                .disabled(model.isLoggingOut || model.accounts.isSwitching)
        }
    }
}

// MARK: - 切换遮罩

/// 切换账号时覆盖窗口的轻量遮罩：进度文字；需要验证码时显示输入框。
struct AccountSwitchOverlay: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let accounts = model.accounts
        if let progress = accounts.switchProgress, accounts.isOverlayVisible {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                card(progress)
                    .padding(22)
                    .frame(width: 360)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func card(_ progress: AccountSwitchProgress) -> some View {
        @Bindable var accounts = model.accounts
        VStack(spacing: 14) {
            Image(systemName: "person.2.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            Text("切换到 \(progress.target.regionTitle) 账号")
                .font(BrandFont.title)
            Text(verbatim: AccountFooter.displayed(account: progress.target).email)
                .font(.callout)
                .foregroundStyle(.secondary)

            if progress.phase == .needsTwoFactor {
                Text(AccountsViewModel.statusText(progress))
                    .font(.callout)
                Text("验证码已推送到该 Apple ID 的所有受信任设备（含 Apple Watch），请在设备通知中查看。此通道不支持短信验证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("验证码", text: $accounts.code, prompt: Text(verbatim: "000000"))
                    .labelsHidden()
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .focused($focused)
                    .onChange(of: accounts.code) { _, newValue in
                        let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != newValue { accounts.code = digits }
                    }
                    .onSubmit { accounts.submitCode() }
                    .onAppear { focused = true }
                if let hint = accounts.codeHint {
                    Label(hint, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("取消切换", role: .cancel) { accounts.cancelSwitch() }
                        .keyboardShortcut(.cancelAction)
                    Button("验证") { accounts.submitCode() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!LoginViewModel.isValidCode(accounts.code))
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AccountsViewModel.statusText(progress))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("切换会重新登录 Apple ID，请稍候。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - 管理账号

struct AccountManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removing: AccountRecord?

    var body: some View {
        let accounts = model.accounts
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("管理账号").font(BrandFont.title)
                Text("密码保存在这台 Mac 的钥匙串中，切换时自动登录。地区只能通过换账号改变，标签仅用于区分。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if accounts.accounts.isEmpty {
                ContentUnavailableView("还没有保存的账号", systemImage: "person.crop.circle.badge.plus")
                    .frame(height: 160)
            } else {
                List {
                    ForEach(accounts.accounts) { account in
                        AccountManagerRow(account: account, isActive: account.id == accounts.active?.id,
                                          onRemove: { removing = account })
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: min(CGFloat(accounts.accounts.count) * 52 + 10, 320))
            }
            if let error = accounts.manageError {
                ErrorDetailView(error: error)
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Button("添加账号…") {
                    dismiss()
                    Task {
                        // 等管理窗口收起后再弹登录窗口（两个 sheet 不能同时出现）
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        model.beginLogin()
                    }
                }
                .disabled(accounts.isSwitching)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onDisappear { model.accounts.manageError = nil }
        .confirmationDialog(removing.map { String(localized: "移除 \(AccountFooter.displayed(account: $0).email)？") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("移除账号", role: .destructive) { Task { await model.removeAccount(account) } }
            Button("取消", role: .cancel) {}
        } message: { account in
            if account.id == model.accounts.active?.id {
                Text("这是当前登录的账号：移除会先退出登录，并删除它保存的会话与钥匙串里的密码。下载记录不受影响。")
            } else {
                Text("会删除它保存的会话与钥匙串里的密码。下载记录不受影响。")
            }
        }
    }
}

private struct AccountManagerRow: View {
    @Environment(AppModel.self) private var model
    let account: AccountRecord
    let isActive: Bool
    let onRemove: () -> Void

    var body: some View {
        let shown = AccountFooter.displayed(account: account)
        HStack(spacing: 10) {
            Picker("地区", selection: Binding(get: { account.regionLabel },
                                              set: { region in
                                                  let code = region == .other ? account.customRegionCode : nil
                                                  Task { await model.accounts.setRegion(region, customCode: code, for: account) }
                                              })) {
                ForEach(RegionCatalog.regions) { region in
                    Text(region.flagTitle).tag(region)
                }
            }
            .labelsHidden()
            .fixedSize()
            if account.regionLabel == .other {
                RegionCodeField(initial: account.customRegionCode ?? "") { code in
                    Task { await model.accounts.setRegion(.other, customCode: code, for: account) }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: shown.email).lineLimit(1).truncationMode(.middle)
                    if isActive { TagView(text: String(localized: "当前")) }
                }
                HStack(spacing: 6) {
                    if !shown.displayName.isEmpty { Text(verbatim: shown.displayName) }
                    if account.passwordState == .saved {
                        Label("密码已保存", systemImage: "key.fill").labelStyle(.titleAndIcon)
                    } else {
                        Label("密码待补", systemImage: "key").labelStyle(.titleAndIcon)
                            .foregroundStyle(.orange)
                    }
                    if let date = account.lastLoginAt {
                        Text(verbatim: "· \(Format.dateTime(date))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(account.passwordState == .saved ? "更新密码…" : "补填密码…") {
                model.accounts.passwordPrompt = AccountPasswordPrompt(account: account, purpose: .update)
            }
            .controlSize(.small)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("移除账号")
            .disabled(model.accounts.isSwitching || (isActive && model.downloads.hasActiveDownload))
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 补填 / 更新密码

struct AccountPasswordSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: AccountPasswordPrompt
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.purpose == .switchTo ? "输入密码以切换账号" : "更新保存的密码")
                .font(BrandFont.title)
            Text(verbatim: "\(prompt.account.regionTitle) · \(AccountFooter.displayed(account: prompt.account).email)")
                .font(.callout)
            Text(prompt.purpose == .switchTo
                 ? "这个账号还没有保存密码。输入后会用它登录，成功后保存到这台 Mac 的钥匙串，以后切换不再询问。"
                 : "新密码会保存到这台 Mac 的钥匙串，下次切换到该账号时使用。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("密码", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.accounts.passwordPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.purpose == .switchTo ? "登录并切换" : "保存", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let secret = password
        password = ""
        let accounts = model.accounts
        let prompt = self.prompt
        Task { await accounts.submitPassword(prompt, password: secret) }
    }
}

// MARK: - 升级迁移：选择地区

struct AccountRegionPromptSheet: View {
    @Environment(AppModel.self) private var model
    let account: AccountRecord
    @State private var region: AccountRegion = .mainlandChina
    @State private var customCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请选择该账号的地区").font(BrandFont.title)
            Text("IPA Depot 现在支持保存多个账号、一键切换地区。已为当前登录的账号建好一条记录，请选一下它所在的地区，方便在侧栏区分。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("账号") {
                Text(verbatim: AccountFooter.displayed(account: account).email)
            }
            RegionPicker(title: "地区", region: $region, customCode: $customCode)
            Text("这个账号的密码尚未保存：切到其他账号后再切回来时，需要补填一次密码。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("稍后") { model.accounts.regionPrompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("确定") {
                    let accounts = model.accounts
                    let account = self.account
                    let region = self.region
                    let code = region == .other ? RegionCatalog.normalizeCode(customCode) : nil
                    accounts.regionPrompt = nil
                    Task { await accounts.setRegion(region, customCode: code, for: account) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

// MARK: - 地区选择（RegionCatalog）

/// 地区 Picker（旗帜 + 名称，按目录排序）；选「其他」时显示两位国家代码输入框。
struct RegionPicker: View {
    let title: LocalizedStringKey
    @Binding var region: AccountRegion
    @Binding var customCode: String

    var body: some View {
        Picker(title, selection: $region) {
            ForEach(RegionCatalog.regions) { region in
                Text(region.flagTitle).tag(region)
            }
        }
        if region == .other {
            TextField("国家代码", text: $customCode, prompt: Text(verbatim: "sg"))
                .onChange(of: customCode) { _, newValue in
                    let letters = String(newValue.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(2))
                    if letters != newValue { customCode = letters }
                }
                .help("两位国家或地区代码，如 sg（新加坡）、gb（英国）")
        }
    }
}

/// 两位国家代码的小输入框：输入满两位有效字母时回调。
struct RegionCodeField: View {
    let initial: String
    let onCommit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("国家代码", text: $text, prompt: Text(verbatim: "sg"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            .onAppear { text = initial }
            .onChange(of: text) { _, newValue in
                let letters = String(newValue.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(2))
                if letters != newValue { text = letters; return }
                if let code = RegionCatalog.normalizeCode(letters), code != initial { onCommit(code) }
            }
            .help("两位国家或地区代码，如 sg（新加坡）、gb（英国）")
    }
}
