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
        .windowToolbarStyle(.unified(showsTitle: false))   // 工具条里已经有仓库名了，标题栏"TwigMac"是多余的重复文字
        .commands {
            // 没有"新建文档"这回事，把默认的 Cmd+N 换成"换仓库"——这也是唯一的
            // 键盘入口，工具条上点仓库名/分支那个胶囊是另一个入口，两处调的是同一个方法。
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { app.openRepoPicker() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
