import SwiftUI

@main
struct TwigMacApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .task { await app.connect() }
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }   // 没有"新建文档"这回事，去掉默认的 Cmd+N
        }
    }
}
