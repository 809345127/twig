import SwiftUI

struct MainLayout: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SidebarView()
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 400)
                    .background(.regularMaterial)
                VSplitView {
                    VStack(spacing: 0) {
                        GraphPane()
                            .frame(minHeight: 150)
                        ConflictStateBanner()
                    }
                    DetailPane()
                        .frame(minHeight: 180)
                }
                .frame(minWidth: 500)
            }
            StatusBar()
        }
        .toolbar { RepoToolbar() }
        .sheet(isPresented: Binding(
            get: { app.showOutputModal },
            set: { app.showOutputModal = $0 }
        )) {
            OutputSheet()
        }
    }
}

// 底部状态栏：对应 web 版的 statusbar。显示当前状态、上一条 git 命令的摘要，
// 点击弹出全文。busy 时显示进度指示器，err 时标红。
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
        .padding(.vertical, 4)
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

// 操作输出弹窗：对应 web 版的 outputModal。显示上一条 git 命令的完整输出。
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                Text(app.lastOutput?.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 620, height: 420)
    }
}
