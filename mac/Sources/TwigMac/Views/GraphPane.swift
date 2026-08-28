import SwiftUI

// 图区几何常量，跟 web/app.js 的 ROW_H / LANE_W / DOT_R / GRAPH_PAD 逐个对齐。
enum GraphMetrics {
    static let rowHeight: CGFloat = 26
    static let laneWidth: CGFloat = 15
    static let dotRadius: CGFloat = 4
    static let pad: CGFloat = 10

    static func laneX(_ lane: Int) -> CGFloat { pad + CGFloat(lane) * laneWidth + laneWidth / 2 }
}

struct GraphPane: View {
    @EnvironmentObject var app: AppState

    var geometry: GraphGeometry? {
        guard let g = app.graph else { return nil }
        return GraphGeometry(graph: g)
    }

    var body: some View {
        VStack(spacing: 0) {
            GraphToolbar()
            Divider()
            if let g = app.graph, let geo = geometry {
                if g.commits.isEmpty {
                    ContentUnavailableView(
                        app.selectedRefs.isEmpty ? "This repository has no commits yet." : "No commits on the checked branches.",
                        systemImage: "point.3.connected.trianglepath.dotted")
                } else {
                    List(Array(g.commits.enumerated()), id: \.element.id, selection: selectionBinding) { idx, commit in
                        CommitRowView(commit: commit, row: geo.rows[idx], graphWidth: geo.laneWidth,
                                      isHead: app.head?.hash == commit.hash)
                            .tag(commit.hash)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // List 原生的单选高亮 + 点击回调；Cmd 点第二个提交进比较模式的逻辑放在 CommitRowView 的手势里，
    // 这里的 selection 只负责"点了哪一行"的基本情形。
    var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if case .commit(let h) = app.detailMode { return h }
                return nil
            },
            set: { newValue in
                guard let hash = newValue else { return }
                Task { await app.selectCommit(hash) }
            }
        )
    }
}

struct GraphToolbar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            Toggle("First parent only", isOn: Binding(
                get: { app.firstParent },
                set: { app.setFirstParent($0) }
            ))
            .toggleStyle(.checkbox)
            .help("Follow only the first parent: merged-in branch detail is collapsed, leaving a single mainline")

            Spacer()

            Picker("Show", selection: Binding(
                get: { app.limit },
                set: { app.limit = $0; Task { await app.reloadGraphOnly() } }
            )) {
                Text("200").tag(200)
                Text("500").tag(500)
                Text("1000").tag(1000)
                Text("3000").tag(3000)
            }
            .frame(width: 120)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
