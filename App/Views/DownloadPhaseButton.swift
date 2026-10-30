import SwiftUI

/// 下载按钮（阶段八）：搜索结果行与历史版本页共用的三态 + 解析中。
/// - 默认：原文案，可点击；
/// - 解析中（公开目录结果在匹配 / 切换 / 添加账号）：小菊花 + 原文案，禁用；
/// - 刚加入（约 1.5 秒）：带勾的「已加入」，禁用；
/// - 已在队列（队列里有匹配的未结束任务）：「已在队列」，禁用；任务完成 / 失败 / 取消后恢复默认。
struct DownloadPhaseButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    let phase: DownloadButtonPhase
    /// 与状态无关的额外禁用条件（如未登录）。
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .disabled(disabled || !phase.isEnabled)
            .help(helpText)
            .animation(.easeInOut(duration: 0.15), value: phase)
    }

    @ViewBuilder
    private var label: some View {
        switch phase {
        case .idle:
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        case .resolving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(title)
            }
        case .justAdded:
            Label("已加入", systemImage: "checkmark")
        case .inQueue:
            Label("已在队列", systemImage: "tray.full")
        }
    }

    private var helpText: Text {
        switch phase {
        case .idle: return Text(verbatim: "")
        case .resolving: return Text("正在匹配该地区的账号…")
        case .justAdded: return Text("已加入下载队列")
        case .inQueue: return Text("下载页里已有这个任务；完成、失败或取消后可再次下载")
        }
    }
}
