import SwiftUI
import IPADepotCore

struct VersionsView: View {
    @Environment(AppModel.self) private var model
    let versions: VersionsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(versions.app.name)
        .task {
            if versions.rows.isEmpty { await versions.load() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(appID: versions.app.id, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(versions.app.name)
                    .font(BrandFont.heroName)
                    .lineLimit(1)
                if let developer = model.artwork.developers[versions.app.id] {
                    Text(developer).font(.callout).foregroundStyle(.secondary)
                }
                appMetadata
            }
            Spacer()
            DownloadPhaseButton(title: "下载最新版", systemImage: "arrow.down.circle",
                                phase: model.downloads.buttonPhase(for: versions.context(for: nil)),
                                disabled: model.account == nil) {
                Task { await model.downloads.enqueue(versions.context(for: nil)) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// 标题下的一行信息：Bundle ID · ID · 当前版本 · 价格。
    private var appMetadata: some View {
        HStack(spacing: 6) {
            if !versions.app.bundleID.isEmpty {
                Text(verbatim: versions.app.bundleID)
                Text(verbatim: "·")
            }
            Text(verbatim: "ID \(versions.app.id)")
            if !versions.app.version.isEmpty {
                Text(verbatim: "·")
                Text("当前版本 \(versions.app.version)")
            }
            Text(verbatim: "·")
            Text(Format.price(versions.app.price))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var content: some View {
        switch versions.phase {
        case .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text("正在获取版本列表…").foregroundStyle(.secondary)
                Text("向 Apple 查询需要一点时间，通常在 30 秒内完成。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .licenseRequired:
            ContentUnavailableView {
                Label("账号还没有这个 App", systemImage: "lock")
            } description: {
                if versions.app.isFree {
                    Text("查看历史版本需要账号拥有该 App 的许可。这是免费 App，可以先领取免费许可（同时下载最新版）。")
                } else {
                    Text("这是付费 App，须先在 App Store 购买后才能查看和下载历史版本。")
                }
            } actions: {
                if versions.app.isFree {
                    DownloadPhaseButton(title: "领取免费许可并下载最新版…",
                                        phase: model.downloads.buttonPhase(for: versions.context(for: nil))) {
                        model.downloads.requestLicense(for: versions.context(for: nil))
                    }
                }
                Button("重新获取") { Task { await versions.load() } }
            }
        case .accountChanged(let region):
            ContentUnavailableView {
                if let region {
                    Label("已切换到 \(region) 账号，请重新搜索", systemImage: "person.2.badge.gearshape")
                } else {
                    Label("已退出登录", systemImage: "person.crop.circle.badge.xmark")
                }
            } description: {
                Text("不同地区账号的版本列表与授权可能不同，需要重新获取。")
            } actions: {
                if model.account != nil {
                    Button("用当前账号重新获取") { Task { await versions.load() } }
                }
            }
        case .failed(let error):
            ContentUnavailableView {
                Label("无法获取版本列表", systemImage: "exclamationmark.triangle")
            } description: {
                ErrorDetailView(error: error).frame(maxWidth: 420)
            } actions: {
                Button("重试") { Task { await versions.load() } }
            }
        case .loaded:
            if versions.rows.isEmpty {
                ContentUnavailableView("没有历史版本", systemImage: "clock.arrow.circlepath")
            } else {
                List {
                    Section {
                        ForEach(versions.rows) { row in
                            VersionRowView(versions: versions, row: row)
                                .onAppear { versions.rowAppeared(row.id) }
                                .onDisappear { versions.rowDisappeared(row.id) }
                        }
                    } header: {
                        Text("共 \(versions.rows.count) 个版本，最新在上 · 已加载 \(versions.loadedCount) 个版本号")
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct VersionRowView: View {
    @Environment(AppModel.self) private var model
    let versions: VersionsViewModel
    let row: VersionsViewModel.Row

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let meta = row.metadata {
                        Text(verbatim: meta.displayVersion.isEmpty ? "—" : meta.displayVersion)
                            .font(BrandFont.version)
                    } else if row.failed {
                        Text("版本号获取失败").foregroundStyle(.secondary)
                        Button("重试") { versions.retry(row.id) }
                            .buttonStyle(.link)
                            .font(.callout)
                    } else {
                        Text(verbatim: "0.0.0")
                            .font(.body.monospacedDigit())
                            .redacted(reason: .placeholder)
                        if versions.loadingIDs.contains(row.id) {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    if row.isLatest { TagView(text: String(localized: "最新")) }
                }
                Text(verbatim: "ID \(row.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let date = row.metadata?.releaseDate {
                Text(Format.date(date))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            DownloadPhaseButton(title: "下载", phase: model.downloads.buttonPhase(for: versions.context(for: row)),
                                disabled: model.account == nil) {
                Task { await model.downloads.enqueue(versions.context(for: row)) }
            }
        }
        .padding(.vertical, 3)
    }
}
