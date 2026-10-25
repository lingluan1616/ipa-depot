import SwiftUI
import IPADepotCore

@main
struct IPADepotApp: App {
    @State private var model = AppModel(services: .live())

    var body: some Scene {
        Window("IPA Depot", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.page = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}
