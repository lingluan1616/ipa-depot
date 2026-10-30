import SwiftUI
import IPADepotCore

struct LoginSheet: View {
    @Bindable var login: LoginViewModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch login.step {
                case .intro: IntroStep(login: login)
                case .credentials: CredentialsStep(login: login)
                case .twoFactor: TwoFactorStep(login: login)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(login.isWorking)
    }
}

// MARK: - 第一步：准备页

private struct IntroStep: View {
    let login: LoginViewModel
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("登录前请了解")
                .font(BrandFont.title)

            VStack(alignment: .leading, spacing: 14) {
                NoticeRow(symbol: "lock.shield",
                          title: "密码只在本机使用",
                          detail: "密码只用于在这台 Mac 上向 Apple 登录，不会上传到其他任何地方。为了一键切换账号，IPA Depot 会把它保存在这台 Mac 的钥匙串里。")
                NoticeRow(symbol: "arrow.down.circle",
                          title: "首次登录需要准备组件",
                          detail: "ipatool 第一次登录时会下载运行所需的组件，可能需要几分钟，请保持网络畅通。")
                NoticeRow(symbol: "key",
                          title: "钥匙串授权会弹两次，都选「始终允许」",
                          detail: "授权框不在登录时出现：登录成功后第一次搜索会弹一次，第一次查看历史版本或下载时再弹一次（两条不同的钥匙串记录），都要输入这台 Mac 的登录密码。两次都选「始终允许」后不再询问。")
                NoticeRow(symbol: "globe.asia.australia",
                          title: "商店地区跟随账号",
                          detail: "搜索与下载以账号所在地区的 App Store 为准；想下其他地区的 App，可在侧栏账号菜单添加该地区的账号，随时一键切换。")
            }

            KeychainPromptIllustration()
                .frame(maxWidth: .infinity)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.dismissLogin() }
                    .keyboardShortcut(.cancelAction)
                Button("继续") { login.continueFromIntro() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct NoticeRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 用 SF Symbols 与原生形状画的「钥匙串授权框」示意（不是截图）。
private struct KeychainPromptIllustration: View {
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Image(systemName: "key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .offset(x: 6, y: 2)
                }
                .frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text("“ipatool”想要使用钥匙串中的机密信息")
                        .font(.caption.weight(.semibold))
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 190, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(.quaternary).frame(width: 140, height: 5)
                    HStack(spacing: 4) {
                        Image(systemName: "ellipsis.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Mac 登录密码")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(width: 190, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                }
            }
            HStack(spacing: 6) {
                FakeButton(title: "拒绝", highlighted: false)
                FakeButton(title: "允许", highlighted: false)
                FakeButton(title: "始终允许", highlighted: true)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.primary)
                            .offset(x: 10, y: 14)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("示意图：系统钥匙串授权框，请点「始终允许」"))
    }

    private struct FakeButton: View {
        let title: LocalizedStringKey
        let highlighted: Bool

        var body: some View {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    if highlighted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 2)
                            .padding(-3)
                    }
                }
        }
    }
}

// MARK: - 第二步：Apple ID 与密码

private struct CredentialsStep: View {
    @Bindable var login: LoginViewModel
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Field?

    enum Field { case appleID, secret }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(login.mode == .addAccount ? "添加账号" : "登录 Apple ID")
                    .font(BrandFont.title)
                Text(login.mode == .addAccount && model.account != nil
                     ? "会先保存并退出当前账号，再登录新账号；新账号的密码保存在这台 Mac 的钥匙串中。"
                     : "搜索与下载使用该账号所在地区的 App Store。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Apple ID", text: $login.appleID, prompt: Text("邮箱或手机号码"))
                    .textContentType(.username)
                    .focused($focused, equals: .appleID)
                    .onSubmit { focused = .secret }
                SecureField("密码", text: $login.password)
                    .textContentType(.password)
                    .focused($focused, equals: .secret)
                    .onSubmit(submit)
                Picker("地区标签", selection: $login.region) {
                    ForEach(AccountRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 150)
            .padding(.horizontal, -20)
            .disabled(login.isWorking)

            if login.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(login.statusText ?? String(localized: "正在登录…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let error = login.error {
                VStack(alignment: .leading, spacing: 6) {
                    ErrorDetailView(error: error)
                    if let note = login.rollbackNote {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                if login.mode == .signIn {
                    Button("返回") { login.step = .intro }
                        .disabled(login.isWorking)
                }
                Spacer()
                Button("取消", role: .cancel) { model.dismissLogin() }
                    .keyboardShortcut(.cancelAction)
                Button("登录", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!login.canSubmitCredentials)
            }
        }
        .onAppear { focused = login.appleID.isEmpty ? .appleID : .secret }
    }

    private func submit() {
        guard login.canSubmitCredentials else { return }
        Task { await login.submitCredentials() }
    }
}

// MARK: - 第三步：双重认证

private struct TwoFactorStep: View {
    @Bindable var login: LoginViewModel
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("双重认证")
                    .font(BrandFont.title)
                Text("请输入受信任设备上显示的 6 位验证码。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                TextField("验证码", text: $login.code, prompt: Text(verbatim: "000000"))
                    .labelsHidden()
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($focused)
                    .disabled(login.isWorking)
                    .onChange(of: login.code) { _, newValue in
                        let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != newValue { login.code = digits }
                    }
                    .onSubmit { login.submitCode() }
                Spacer()
            }

            if login.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(login.statusText ?? String(localized: "正在验证…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let hint = login.codeHint {
                Label(hint, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { model.dismissLogin() }
                    .keyboardShortcut(.cancelAction)
                Button("验证") { login.submitCode() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!login.isCodeValid || login.isWorking)
            }
        }
        .onAppear { focused = true }
    }
}
