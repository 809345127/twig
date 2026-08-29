import SwiftUI

@main
struct TwigMacApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("Twig") {
            ContentView()
                .environmentObject(app)
                .task { await app.connect() }
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    // 窗口首次出现时设置 tabbing 模式，支持多标签页
                    NSWindow.allowsAutomaticWindowTabbing = true
                }
        }
        .windowResizability(.contentSize)
        // 统一标题栏 + 隐藏标题文字（工具条里已经有仓库名）
        .windowToolbarStyle(.unified(showsTitle: false))
        // 让窗口支持全屏、标签页等标准 macOS 行为
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
            // 视图菜单：显示/隐藏侧边栏（标准 macOS 快捷键 Cmd+Option+S）
            CommandGroup(after: .toolbar) {
                Button("Toggle Sidebar") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
            // Esc 退出比较模式：web 版 Esc 先关弹窗、没弹窗就退出比较。
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
