import SwiftUI
import IPADepotCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var shownLicense: SettingsViewModel.License?

    var body: some View {
        let settings = model.settings
        Form {
            Section("下载") {
                LabeledContent("下载位置") {
                    HStack(spacing: 8) {
                        Text(verbatim: (settings.downloadDirectory.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(settings.downloadDirectory.path(percentEncoded: false))
                        Button("选择…") { chooseDirectory() }
                    }
                }
                HStack {
                    Text("文件名格式：名称_版本.ipa；同名文件已存在时自动加序号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认") { settings.resetDownloadDirectory() }
                        .disabled(settings.downloadDirectory == SettingsViewModel.defaultDownloadDirectory)
                }
            }

            Section {
                LabeledContent("版本信息缓存", value: Format.bytes(settings.versionsCacheSize))
                LabeledContent("图标缓存", value: Format.bytes(settings.artworkCacheSize))
                HStack {
                    Text("只清理 IPA Depot 自己的缓存，不影响 ipatool 的组件缓存与登录状态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if settings.isClearingCache { ProgressView().controlSize(.small) }
                    Button("清理") { Task { await settings.clearCache() } }
                        .disabled(settings.isClearingCache || settings.totalCacheSize == 0)
                }
            } header: {
                Text("缓存")
            }

            Section("关于") {
                LabeledContent("IPA Depot", value: settings.appVersion)
                LabeledContent("内置 ipatool") {
                    if let version = settings.ipatoolVersion {
                        Text(verbatim: version)
                    } else if let error = settings.ipatoolVersionError {
                        Text(error).foregroundStyle(.red).lineLimit(2)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                LabeledContent("项目地址") {
                    if let url = ProjectInfo.projectURL {
                        Link(ProjectInfo.displayURL, destination: url)
                    } else {
                        Text(verbatim: ProjectInfo.displayURL).foregroundStyle(.secondary)
                    }
                }
            }

            Section("许可") {
                LabeledContent("IPA Depot") {
                    HStack(spacing: 8) {
                        Text("MIT 许可").foregroundStyle(.secondary)
                        Button("许可全文…") { shownLicense = .app }
                    }
                }
                LabeledContent("ipatool") {
                    HStack(spacing: 8) {
                        Link("基于 majd/ipatool（MIT）", destination: ProjectInfo.ipatoolURL)
                        Button("许可全文…") { shownLicense = .ipatool }
                    }
                }
                LabeledContent("阿里妈妈数黑体") {
                    HStack(spacing: 8) {
                        Text("不在 MIT 范围内").foregroundStyle(.secondary)
                        Button("法律声明…") { shownLicense = .font }
                    }
                }
            }

            Section("更新") {
                HStack {
                    updateStatus
                    Spacer()
                    if settings.updateState == .checking { ProgressView().controlSize(.small) }
                    Button("检查更新") { Task { await settings.checkForUpdates() } }
                        .disabled(!settings.canCheckForUpdates)
                }
                if case .available(let release) = settings.updateState {
                    HStack {
                        Text("新版本 \(release.version) 已发布。")
                        Spacer()
                        Button("打开下载页面") { openURL(release.htmlURL) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .task {
            await settings.refreshCacheSizes()
            await settings.loadIpatoolVersion()
        }
        .sheet(item: $shownLicense) { license in
            LicenseSheet(license: license, text: settings.licenseText(license))
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        let settings = model.settings
        switch settings.updateState {
        case .idle:
            if settings.owner == nil {
                Text("发布地址尚未配置，暂不能检查更新。").foregroundStyle(.secondary)
            } else {
                Text("当前版本 \(settings.appVersion)").foregroundStyle(.secondary)
            }
        case .checking:
            Text("正在检查…").foregroundStyle(.secondary)
        case .upToDate(let latest):
            Text("已是最新版本（\(latest)）。").foregroundStyle(.secondary)
        case .available:
            Text("有可用的新版本。")
        case .failed(let error):
            Text(error.message).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.settings.downloadDirectory
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: "选择 IPA 安装包的保存位置")
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.setDownloadDirectory(url)
        }
    }
}

private struct LicenseSheet: View {
    let license: SettingsViewModel.License
    let text: String?
    @Environment(\.dismiss) private var dismiss

    private var title: LocalizedStringKey {
        switch license {
        case .app: return "IPA Depot 许可（MIT）"
        case .ipatool: return "ipatool 许可（MIT）"
        case .font: return "阿里妈妈数黑体法律声明"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text ?? String(localized: "未找到许可文件（Contents/Resources/\(license.resourcePath)）。"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}
