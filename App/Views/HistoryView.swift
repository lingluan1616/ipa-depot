import SwiftUI
import IPADepotCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    var body: some View {
        let history = model.history
        Group {
            if history.records.isEmpty {
                ContentUnavailableView {
                    Label("还没有下载记录", systemImage: "clock")
                } description: {
                    Text("下载完成的安装包会记录在这里。")
                }
            } else {
                List {
                    ForEach(history.records) { record in
                        HistoryRow(record: record, exists: history.exists(record))
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("记录")
        .toolbar {
            ToolbarItem {
                Button("清空记录") { confirmingClear = true }
                    .disabled(history.records.isEmpty)
            }
        }
        .confirmationDialog("清空全部下载记录？", isPresented: $confirmingClear) {
            Button("清空记录", role: .destructive) { history.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清除记录，不会删除已下载的安装包文件。")
        }
        .errorAlert(Binding(get: { history.saveError }, set: { _ in }), title: "无法保存下载记录")
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let record: DownloadRecord
    let exists: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(appID: record.appID, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.name).font(BrandFont.name).lineLimit(1)
                    Text(verbatim: record.version)
                        .font(BrandFont.number)
                        .foregroundStyle(.secondary)
                    if !exists { TagView(text: String(localized: "文件已不存在")) }
                }
                HStack(spacing: 6) {
                    Text(verbatim: record.bundleID)
                    if let ext = record.externalVersionID {
                        Text(verbatim: "· ID \(ext)")
                    }
                    Text(verbatim: "·")
                    Text(verbatim: Format.bytes(record.size)).font(BrandFont.smallNumber)
                    Text(verbatim: "· \(Format.dateTime(record.completedAt))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(verbatim: record.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                Finder.reveal(record.fileURL)
            } label: {
                Label("在访达中显示", systemImage: "magnifyingglass.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 17))
            .disabled(!exists)
            .help("在访达中显示")
            Button {
                model.history.remove(record.id)
            } label: {
                Label("从记录移除", systemImage: "xmark.circle").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 17))
            .help("从记录移除")
        }
        .padding(.vertical, 4)
        .opacity(exists ? 1 : 0.5)
        .contextMenu {
            Button("在访达中显示") { Finder.reveal(record.fileURL) }.disabled(!exists)
            Button("从记录移除") { model.history.remove(record.id) }
        }
    }
}
