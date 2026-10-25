import SwiftUI
import IPADepotCore

/// 阶段一占位窗口：只显示内置 ipatool 的位置与版本，界面在阶段二实现。
struct ContentView: View {
    @State private var status = "正在检测 ipatool…"
    @State private var path = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("IPA Depot")
                .font(.largeTitle.bold())
            Text(status)
                .foregroundStyle(.secondary)
            if !path.isEmpty {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(32)
        .task { await detect() }
    }

    private func detect() async {
        let locator = IpatoolLocator()
        do {
            path = try locator.locate().path
            let version = try await locator.detectVersion()
            status = "ipatool \(version) 就绪"
        } catch let error as IpatoolError {
            status = error.message
        } catch {
            status = error.localizedDescription
        }
    }
}
