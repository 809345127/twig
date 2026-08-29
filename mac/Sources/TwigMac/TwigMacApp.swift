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
            // 没有"新建文档"这回事，把默认的 Cmd+N 换成"换仓库"。
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { app.openRepoPicker() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // 刷新：对应 web 版按 'r' 刷新。
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await app.refreshAll() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            // Esc 退出比较模式：web 版 Esc 先关弹窗、没弹窗就退出比较。
            // 这里用一个不可见的命令按钮接住 Esc，只在比较模式下有动作。
            CommandGroup(after: .help) {
                Button("Exit Compare") {
                    if case .compare(let from, _) = app.detailMode {
                        Task { await app.selectCommit(from) }
                    }
                }
                .keyboardShortcut(.escape)
            }
        }
    }
}
