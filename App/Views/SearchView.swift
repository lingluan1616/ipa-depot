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

            BrowseRegionPicker()

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

/// 「浏览地区」：跟随当前账号（ipatool 搜索）或指定地区（Apple 公开目录）。选「其他」时填两位代码。
private struct BrowseRegionPicker: View {
    @Environment(AppModel.self) private var model
    @State private var customCode = ""

    var body: some View {
        let search = model.search
        HStack(spacing: 4) {
            Picker("浏览地区", selection: Binding<AccountRegion?>(
                get: { search.browseRegion.region },
                set: { region in
                    guard let region else { search.setBrowseRegion(.followAccount); return }
                    let code = region == .other ? RegionCatalog.normalizeCode(customCode) : nil
                    search.setBrowseRegion(.region(region, customCode: code))
                })) {
                Text("跟随当前账号").tag(AccountRegion?.none)
                Divider()
                ForEach(RegionCatalog.regions) { region in
                    Text(region.flagTitle).tag(AccountRegion?.some(region))
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("浏览地区：只影响搜索目录；下载仍需该地区的账号")
            if search.browseRegion.region == .other {
                TextField("国家代码", text: $customCode, prompt: Text(verbatim: "sg"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .onChange(of: customCode) { _, newValue in
                        let letters = String(newValue.lowercased().filter { $0.isASCII && $0.isLetter }.prefix(2))
                        if letters != newValue { customCode = letters; return }
                        if let code = RegionCatalog.normalizeCode(letters) {
                            search.setBrowseRegion(.region(.other, customCode: code))
                        }
                    }
                    .help("两位国家或地区代码，如 sg（新加坡）、gb（英国）")
            }
        }
        .onAppear {
            if case .region(.other, let code) = search.browseRegion { customCode = code ?? "" }
        }
    }
}

private struct SearchResults: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.search
        Group {
            switch search.phase {
            case .idle:
                if let region = search.browseRegionTitle {
                    ContentUnavailableView {
                        Label("浏览 \(region) 公开目录", systemImage: "globe")
                    } description: {
                        Text("输入名称或关键词，在 \(region) App Store 的公开目录中搜索（不需要登录）。查看历史版本与下载时需要一个 \(region) 地区的账号。")
                    }
                } else if search.isBrowsingCatalog == false && search.browseRegion != .followAccount {
                    ContentUnavailableView {
                        Label("请填写国家代码", systemImage: "globe")
                    } description: {
                        Text("选择「其他」时，请在旁边填写两位国家或地区代码，如 sg（新加坡）。")
                    }
                } else if model.account == nil && model.accountState != .checking {
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
                    if let region = search.browseRegionTitle {
                        Text("\(region) 公开目录中没有与「\(search.lastQuery ?? "")」匹配的 App。换个关键词、平台或浏览地区再试试。")
                    } else {
                        Text("没有与「\(search.lastQuery ?? "")」匹配的 App。换个关键词或平台再试试；搜索结果来自账号所在地区的商店。")
                    }
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
            ArtworkView(appID: row.id, size: 48, app: row.isPublicCatalog ? row.app : nil)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(BrandFont.name)
                        .lineLimit(1)
                    ForEach(row.platformTags, id: \.self) { TagView(text: $0) }
                    if row.isPublicCatalog {
                        TagView(text: String(localized: "公开目录"))
                            .help("来自 Apple 公开目录（浏览地区），与当前账号无关")
                    }
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
            DownloadPhaseButton(title: "下载最新版", phase: model.downloadPhase(for: row),
                                disabled: model.account == nil && !row.isPublicCatalog) {
                model.perform(.download(row))
            }
            DownloadPhaseButton(title: "历史版本…",
                                phase: model.isResolving(.versions(row)) ? .resolving : .idle) {
                model.perform(.versions(row))
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
