import SwiftUI
import IPADepotCore

struct SearchView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.searchPath) {
            VStack(spacing: 0) {
                SearchBar()
                Divider()
                SearchResults()
            }
            .navigationTitle("搜索")
            .navigationDestination(for: AppRowModel.self) { row in
                VersionsView(versions: model.versionsModel(for: row))
            }
        }
    }
}

private struct SearchBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var search = model.search
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索 App 名称或关键词", text: $search.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { search.submit() }
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清除")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator))

            Picker("平台", selection: $search.platform) {
                ForEach(SearchPlatform.allCases) { platform in
                    Text(verbatim: platform.title).tag(platform)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("平台")

            Picker("数量", selection: $search.limit) {
                ForEach(SearchViewModel.limits, id: \.self) { limit in
                    Text("\(limit) 个结果").tag(limit)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("结果数量")

            Button("搜索") { search.submit() }
                .disabled(!search.canSearch)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: search.platform) { _, _ in
            if search.lastQuery != nil, search.canSearch { search.submit() }
        }
        .onChange(of: search.limit) { _, _ in
            if search.lastQuery != nil, search.canSearch { search.submit() }
        }
        .onAppear { focused = search.query.isEmpty }
    }
}

private struct SearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        Group {
            switch search.phase {
            case .idle:
                if model.account == nil && model.accountState != .checking {
                    SignedOutView()
                } else {
                    ContentUnavailableView {
                        Label("搜索 App", systemImage: "magnifyingglass")
                    } description: {
                        Text("输入名称或关键词，在账号所在地区的 App Store 中搜索，然后下载最新版或历史版本。")
                    }
                }
            case .loading:
                ProgressView("正在搜索…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView {
                    Label("没有找到结果", systemImage: "magnifyingglass")
                } description: {
                    Text("没有与「\(search.lastQuery ?? "")」匹配的 App。换个关键词或平台再试试；搜索结果来自账号所在地区的商店。")
                }
            case .signedOut:
                SignedOutView()
            case .accountChanged(let region):
                ContentUnavailableView {
                    Label("已切换到 \(region) 账号，请重新搜索", systemImage: "person.2.badge.gearshape")
                } description: {
                    Text("搜索结果来自账号所在地区的 App Store，切换账号后需要重新搜索。")
                } actions: {
                    if search.canSearch {
                        Button("重新搜索「\(search.trimmedQuery)」") { search.submit() }
                    }
                }
            case .failed(let error):
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.triangle")
                } description: {
                    ErrorDetailView(error: error)
                        .frame(maxWidth: 420)
                } actions: {
                    Button("重试") { search.submit() }
                }
            case .results:
                List {
                    ForEach(search.rows) { row in
                        AppResultRow(row: row)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SignedOutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("尚未登录", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("登录 Apple ID 后才能搜索与下载。")
        } actions: {
            Button("登录…") { model.beginLogin() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct AppResultRow: View {
    @Environment(AppModel.self) private var model
    let row: AppRowModel

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(appID: row.id, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(BrandFont.name)
                        .lineLimit(1)
                    ForEach(row.platformTags, id: \.self) { TagView(text: $0) }
                }
                if let developer = model.artwork.developers[row.id] {
                    Text(developer)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(verbatim: row.bundleID)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !row.version.isEmpty {
                        Text(verbatim: "·")
                        Text("版本")
                        Text(verbatim: row.version).font(BrandFont.smallNumber)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(row.priceText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(row.isFree ? .secondary : .primary)
                .frame(minWidth: 44, alignment: .trailing)
            Button("下载最新版") {
                let context = DownloadContext(app: row.app, platform: row.platform,
                                              externalVersionID: nil, versionLabel: row.version)
                Task { await model.downloads.enqueue(context) }
            }
            .disabled(model.account == nil)
            Button("历史版本…") {
                model.searchPath.append(row)
            }
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("拷贝 Bundle ID") { copy(row.bundleID) }
            Button("拷贝 App ID") { copy(String(row.id)) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
