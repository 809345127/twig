import SwiftUI

struct MainLayout: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 400)
                    // macOS HIG：侧边栏用半透明毛玻璃效果，让窗口后面的内容透过来。
                    // .ultraThinMaterial 比 .regularMaterial 更通透，更符合现代 macOS 观感。
                    .background(.ultraThinMaterial)

                VSplitView {
                    VStack(spacing: 0) {
                        GraphPane()
                            .frame(minHeight: 180)
                        ConflictStateBanner()
                    }
                    // 主内容区用不透明背景，和侧边栏的通透形成对比。
                    .background(Color(nsColor: .windowBackgroundColor))

                    DetailPane()
                        .frame(minHeight: 200)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
                .frame(minWidth: 560)
            }
            StatusBar()
        }
        .toolbar { RepoToolbar() }
        // 工具栏允许自定义（右键工具栏 → Customize Toolbar…），符合 macOS HIG。
        .onAppear {
            if let window = NSApp.keyWindow {
                window.toolbar?.allowsUserCustomization = true
                window.toolbar?.autosavesConfiguration = true
            }
        }
        .sheet(isPresented: Binding(
            get: { app.showOutputModal },
            set: { app.showOutputModal = $0 }
        )) {
            OutputSheet()
        }
    }
}

// 底部状态栏：对应 web 版的 statusbar，也符合 macOS HIG 的窗口底部状态条。
struct StatusBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            if app.busy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .lineLimit(1)
            Spacer()
            if app.lastOutput != nil {
                Button("output") {
                    app.showOutputModal = true
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // 状态栏用 .bar 材质，和工具栏统一，符合 macOS HIG。
        .background(.bar)
        .onTapGesture {
            if app.lastOutput != nil { app.showOutputModal = true }
        }
    }

    private var statusText: String {
        if !app.statusMessage.isEmpty { return app.statusMessage }
        if let g = app.graph {
            return "\(g.commits.count) commit\(g.commits.count == 1 ? "" : "s")"
        }
        return "Ready"
    }

    private var statusColor: Color {
        switch app.statusKind {
        case "busy": return .secondary
        case "err": return .red
        default: return .secondary
        }
    }
}

// 操作输出弹窗：对应 web 版的 outputModal。
struct OutputSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.lastOutput?.title ?? "Output")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                Text(app.lastOutput?.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 640, height: 440)
    }
}
