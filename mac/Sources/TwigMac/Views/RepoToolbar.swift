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
                            .truncationMode(.middle)   // 分支名前后两段都有信息量（如
                            // feature/…-cross-border），掐中间比掐尾巴更看得出是哪条分支
                    }
                }
                // 系统给 .navigation 位置的自定义内容自动套一个圆角底，那层底几乎不留
                // 内边距——文字第一个字符正好卡在圆角开始弯曲的地方，字没被真的裁掉
                // （放大截图看字形完整），但视觉上就像被那道弧线咬掉一块。加左右内边距
                // 把文字往里推，躲开圆角。宽度相应加大，保证文字实际可用宽度不缩水。
                .padding(.horizontal, 10)
                .frame(width: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Open a different repository…")
        }
        ToolbarItemGroup {
            Button { Task { await app.runOp(.init(action: "fetch")) } } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { Task { await app.runOp(.init(action: "pull")) } } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            Button { Task { await app.runOp(.init(action: "push")) } } label: {
                Label("Push", systemImage: "arrow.up.circle")
            }
        }
        // 独立成第二个 ToolbarItemGroup，让系统按标准的组间距处理——
        // 之前用裸 Divider() 塞在同一组里，在"图标+文字"这种系统工具条显示模式下
        // 会被拉伸成一根贯穿整个按钮高度的竖线，跟滚动条撞脸，还带出一大段空白。
        ToolbarItemGroup {
            Button { Task { await app.refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(app.busy)
        }
    }
}
