import SwiftUI

struct RepoToolbar: ToolbarContent {
    @EnvironmentObject var app: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // 之前这里只是一段静态文字，没有任何点击入口——网页版"换仓库"靠的是
            // 自己实现的文件夹浏览弹窗（/api/browse），原生这边一直没接。用 Button
            // 包一层，点这个仓库名/分支的胶囊就能弹系统原生的选择文件夹面板。
            Button { app.openRepoPicker() } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(app.repo?.name ?? "").font(.headline)
                        .lineLimit(1)
                    if let h = app.head {
                        Text(h.detached ? "detached @ \(String(h.hash.prefix(8)))" : h.branch)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // 系统给 .navigation 位置的自定义内容自动套一个圆角底，那层底几乎不留
                // 内边距——文字第一个字符正好卡在圆角开始弯曲的地方。加左右内边距
                // 把文字往里推，躲开圆角。
                .padding(.horizontal, 10)
                // ⚠️ 宽度必须是弹性的（上限 220），不能写死。.navigation 项的区域宽度
                // 会跟踪 HSplitView 第一条分隔线（实测：胶囊跟侧边栏一样宽）。侧边栏
                // minWidth 是 220，而写死 220 的内容 + padding 要 240——分隔线拖到
                // 最小宽度附近时可用区域装不下内容，工具栏在临界点突然裁剪重排，
                // 肉眼看到就是"拖到胶囊位置闪一下"（2026-08-29 用户实测复现）。
                // 弹性宽度让文字随区域收窄平滑截断，没有临界点。
                .frame(maxWidth: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open a different repository…")
        }

        ToolbarItemGroup {
            // Pull/Push 带 ahead/behind 角标（数据本来就在 refs 里）：
            // 要不要拉/推一眼可见，不用点开分支行去找。
            // busy 时禁用，防止连点发出两条一样的命令。
            let behind = app.currentBranchRef?.behind ?? 0
            let ahead = app.currentBranchRef?.ahead ?? 0
            Button { Task { await app.runOp(.init(action: "fetch"), label: "Fetch") } } label: {
                Label("Fetch", systemImage: "arrow.down.circle")
            }
            .disabled(app.busy)
            Button { Task { await app.runOp(.init(action: "pull"), label: "Pull") } } label: {
                Label(behind > 0 ? "Pull ↓\(behind)" : "Pull", systemImage: "arrow.down.left.circle")
            }
            .disabled(app.busy)
            Button { Task { await app.runOp(.init(action: "push"), label: "Push") } } label: {
                Label(ahead > 0 ? "Push ↑\(ahead)" : "Push", systemImage: "arrow.up.circle")
            }
            .disabled(app.busy)
        }

        // 新建分支 / Stash：交互逻辑收在 AppState（菜单、侧边栏共用同一套）。
        ToolbarItemGroup {
            Button { app.newBranchPrompt() } label: {
                Label("New Branch", systemImage: "plus.circle")
            }
            .disabled(app.busy)
            Button { app.stashPrompt() } label: {
                Label("Stash", systemImage: "tray.and.arrow.down")
            }
            .disabled(app.busy)
        }

        // 独立成第二个 ToolbarItemGroup，让系统按标准的组间距处理——
        // 之前用裸 Divider() 塞在同一组里，在"图标+文字"模式下会被拉伸成竖线。
        ToolbarItemGroup {
            Button { Task { await app.refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }
}

// merge / rebase 中途的状态横幅：显示当前在什么操作中，给 Continue / Abort 按钮。
// 对应 web 版 renderToolbar 里 repoState 那一块。放在 MainLayout 里、图工具条下面。
struct ConflictStateBanner: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if let state = app.status?.state, !state.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(label) — resolve conflicts to continue")
                    .font(.callout)
                Spacer()
                // merge 没有 continue（merge 冲突解决完直接 commit 就行），
                // rebase/cherry-pick/revert 才有 continue。
                if state != "merge" {
                    Button("Continue") {
                        Task { await app.runOp(.init(action: "continue", state: state), label: "Continue \(label)") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
                Button("Abort") {
                    Task { await app.runOp(.init(action: "abort", state: state), label: "Abort \(label)") }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.1))
        }
    }

    private var label: String {
        guard let state = app.status?.state else { return "" }
        switch state {
        case "merge": return "Merging"
        case "rebase": return "Rebasing"
        case "cherry-pick": return "Cherry-picking"
        case "revert": return "Reverting"
        default: return state.capitalized
        }
    }
}
