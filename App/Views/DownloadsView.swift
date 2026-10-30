import SwiftUI
import IPADepotCore

struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = model.downloads
        Group {
            if downloads.rows.isEmpty {
                ContentUnavailableView {
                    Label("没有下载任务", systemImage: "arrow.down.circle")
                } description: {
                    Text("在搜索页点「下载最新版」，或在历史版本里选择一个版本下载。任务会依次进行，同一时间只下载一个。")
                }
            } else {
                List {
                    if !downloads.activeRows.isEmpty {
                        Section("进行中") {
                            ForEach(downloads.activeRows) { row in
                                DownloadRowView(row: row)
                            }
                        }
                    }
                    if !downloads.completedRows.isEmpty {
                        Section {
                            ForEach(downloads.completedRows) { row in
                                DownloadRowView(row: row)
                            }
                        } header: {
                            HStack {
                                Text("已完成")
                                Spacer()
                                Button("清除已完成") { downloads.clearCompleted() }
                                    .buttonStyle(.link)
                                    .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem {
                Button {
                    if let dir = try? model.settings.ensureDownloadDirectory() { Finder.reveal(dir) }
                } label: {
                    Label("打开下载文件夹", systemImage: "folder")
                }
                .help("打开下载文件夹")
            }
        }
    }
}

private struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    let row: DownloadRow
    @State private var showingRaw = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(appID: row.context.appID, size: 40)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.context.name)
                        .font(BrandFont.name)
                        .lineLimit(1)
                    Text(verbatim: row.context.versionLabel)
                        .font(BrandFont.number)
                        .foregroundStyle(.secondary)
                    if let region = row.regionTitle, row.isPublicCatalog || !model.accounts.accounts.isEmpty {
                        TagView(text: region)
                            .help("下载所用账号的地区")
                    }
                    if row.isPublicCatalog {
                        TagView(text: String(localized: "公开目录"))
                            .help("从「浏览地区」的公开目录发起")
                    }
                }
                progress
                HStack(spacing: 8) {
                    Text(row.statusText)
                        .foregroundStyle(row.isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(showingRaw ? nil : 2)
                    if let raw = row.errorRaw {
                        Button(showingRaw ? "收起原始错误" : "查看原始错误") { showingRaw.toggle() }
                            .buttonStyle(.link)
                            .help(raw)
                    }
                    Spacer()
                    if let percent = row.percentText {
                        Text(verbatim: percent).font(BrandFont.smallNumber)
                    }
                    if let size = row.sizeText {
                        Text(verbatim: size).font(BrandFont.smallNumber)
                    }
                    if let speed = row.speedText {
                        Text(verbatim: speed).font(BrandFont.smallNumber)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if showingRaw, let raw = row.errorRaw {
                    Text(raw)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            buttons
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var progress: some View {
        switch row.status {
        case .running, .stopping, .verifying:
            if let fraction = row.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        case .paused:
            ProgressView(value: row.fraction ?? 0).tint(.secondary)
        case .failed:
            // 失败的任务保留已下载部分（`.tmp`），重试时续传
            ProgressView(value: row.fraction ?? 0).tint(.red)
        case .queued:
            ProgressView(value: 0)
        case .switchingAccount:
            ProgressView().progressViewStyle(.linear).tint(.secondary)
        case .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 4) {
            if row.status.isFinished {
                if let url = row.fileURL {
                    iconButton("在访达中显示", symbol: "magnifyingglass.circle") { Finder.reveal(url) }
                }
                iconButton("从列表移除", symbol: "xmark.circle") { model.downloads.remove(row.id) }
            } else {
                if row.canResume {
                    iconButton(row.isRetry ? "重试" : "继续", symbol: row.isRetry ? "arrow.clockwise.circle" : "play.circle") {
                        model.downloads.resume(row.id)
                    }
                } else if row.canPause {
                    iconButton("暂停", symbol: "pause.circle") { model.downloads.pause(row.id) }
                        .disabled(row.status == .stopping)
                }
                iconButton("取消", symbol: "xmark.circle") { model.downloads.cancel(row.id) }
                    .disabled(!row.canCancel)
            }
        }
        .font(.system(size: 17))
    }

    private func iconButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}
