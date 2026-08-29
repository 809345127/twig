import SwiftUI
import AppKit

// 图区几何常量：横向的 laneWidth / dotRadius / pad 跟 web/app.js 的
// LANE_W / DOT_R / GRAPH_PAD 逐个对齐（这几个只影响图区宽度，跟行高无关）。
// rowHeight 不能照抄网页版的 ROW_H=26——网页版每行是"一行文字"（subject/author/
// date/hash 横排在同一行），这里是两行文字（第一行 徽章+subject，第二行
// author·hash·date），26pt 装不下两行会导致 List 行溢出、上下行文字叠在一起。
enum GraphMetrics {
    static let rowHeight: CGFloat = 40
    static let laneWidth: CGFloat = 15
    static let dotRadius: CGFloat = 4
    static let pad: CGFloat = 10

    static func laneX(_ lane: Int) -> CGFloat { pad + CGFloat(lane) * laneWidth + laneWidth / 2 }

    // 图列（画布）总宽度：跟网页版 graphW = max(60, GRAPH_PAD*2 + width*LANE_W) 一致。
    // 所有行（提交行 + 未提交改动行）都用这个值，文字列才能垂直对齐。
    static func graphColumnWidth(lanes: Int) -> CGFloat {
        max(60, pad * 2 + CGFloat(lanes) * laneWidth)
    }
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
                    // ScrollViewReader 让 "Locate in graph" 能把目标行滚到可视区中央。
                    ScrollViewReader { proxy in
                        List(selection: selectionBinding) {
                            // 未提交改动行：有未暂存/已暂存文件时显示在图最上面。
                            if let st = app.status, !st.clean {
                                WorkingCopyRow(fileCount: st.staged.count + st.unstaged.count + st.conflicts.count,
                                               graphWidth: geo.laneWidth)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(Array(g.commits.enumerated()), id: \.element.id) { idx, commit in
                                CommitRowView(commit: commit, row: geo.rows[idx], graphWidth: geo.laneWidth,
                                              isHead: app.head?.hash == commit.hash,
                                              selected: isSelected(commit.hash),
                                              compareFrom: isCompareFrom(commit.hash),
                                              compareTo: isCompareTo(commit.hash))
                                    .tag(commit.hash)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                                    .contextMenu { commitContextMenu(commit) }
                            }
                        }
                        .listStyle(.plain)
                        // 跟侧边栏、文件清单一样藏掉 List 默认背景，透出统一的窗口底色。
                        .scrollContentBackground(.hidden)
                        .onChange(of: app.graphScrollRequest) { _, request in
                            guard let request else { return }
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(request.hash, anchor: .center)
                            }
                        }
                    }
                }
                GraphStats()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // 选中状态判断：传给 CommitRowView 让它自己画背景（hover + 选中 + 比较模式统一处理）。
    private func isSelected(_ hash: String) -> Bool {
        if case .commit(let h) = app.detailMode { return h == hash }
        return false
    }

    private func isCompareFrom(_ hash: String) -> Bool {
        if case .compare(let from, _) = app.detailMode { return hash == from }
        return false
    }

    private func isCompareTo(_ hash: String) -> Bool {
        if case .compare(_, let to) = app.detailMode { return hash == to }
        return false
    }

    // 提交右键菜单：对应 web 的 showCommitMenu。
    @ViewBuilder
    private func commitContextMenu(_ c: Commit) -> some View {
        Text("\(c.short)  \(c.subject)").font(.caption).foregroundStyle(.secondary)
        // 如果当前选中了另一个提交，给出"比较"入口。
        if case .commit(let anchor) = app.detailMode, anchor != c.hash {
            Button("Compare with \(String(anchor.prefix(8)))") {
                Task { await app.compareWith(c.hash) }
            }
            Divider()
        }
        Button("Checkout this commit (detached HEAD)") {
            Task { await app.checkoutCommit(c.hash) }
        }
        Button("Create branch here…") {
            if let r = app.askInput(title: "New Branch", message: "Starting from \(c.short)",
                                     placeholder: "feature/my-branch",
                                     checkboxLabel: "Check out after creating", checkboxChecked: true) {
                Task { await app.runOp(.init(action: "createBranch", name: r.value,
                                              startPoint: c.hash, checkout: r.checked),
                                        label: "Create branch \(r.value)") }
            }
        }
        Divider()
        Button("Merge into current branch") {
            Task { await app.runOp(.init(action: "merge", target: c.hash), label: "Merge \(c.short)") }
        }
        Button("Rebase current branch onto this") {
            Task { await app.runOp(.init(action: "rebase", target: c.hash), label: "Rebase onto \(c.short)") }
        }
        Divider()
        Button("Copy full SHA") { app.copyToClipboard(c.hash) }
        Button("Copy commit message") { app.copyToClipboard(c.subject) }
        Divider()
        Button("Reset current branch here (keep changes)") {
            Task { await app.runOp(.init(action: "reset", target: c.hash, mode: "mixed"),
                                    label: "Reset to \(c.short)") }
        }
        Button("Reset current branch here (discard changes)", role: .destructive) {
            Task { await app.hardReset(to: c.hash) }
        }
    }

    // List 原生的单选高亮 + 点击回调；Cmd 点第二个提交进比较模式。
    var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if case .commit(let h) = app.detailMode { return h }
                return nil
            },
            set: { newValue in
                guard let hash = newValue else { return }
                // 按住 Cmd 点第二个提交 = 比较两个版本，跟网页版的手势一致。
                if NSEvent.modifierFlags.contains(.command) {
                    Task { await app.compareWith(hash) }
                } else {
                    Task { await app.selectCommit(hash) }
                }
            }
        )
    }
}

// 图下面的统计行：对应 web 的 graphStat。
struct GraphStats: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 6) {
            if let g = app.graph {
                Text("\(g.commits.count) commit\(g.commits.count == 1 ? "" : "s")")
                Text("·").foregroundStyle(.tertiary)
                Text("\(g.width) lane\(g.width == 1 ? "" : "s")")
                Text("·").foregroundStyle(.tertiary)
                if app.selectedRefs.isEmpty {
                    Text("all branches")
                } else {
                    Text("\(app.selectedRefs.count) branch\(app.selectedRefs.count == 1 ? "" : "es")")
                }
                if app.firstParent {
                    Text("·").foregroundStyle(.tertiary)
                    Text("first parent only")
                }
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // 统计行用 .bar 材质，和底部状态栏、顶部工具栏统一，符合 macOS HIG。
        .background(.bar)
    }
}

struct GraphToolbar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 16) {
            Toggle("First parent only", isOn: Binding(
                get: { app.firstParent },
                set: { app.setFirstParent($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("Follow only the first parent: merged-in branch detail is collapsed, leaving a single mainline")

            Toggle("Auto refresh", isOn: Binding(
                get: { app.autoRefresh },
                set: { app.setAutoRefresh($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)
            .help("Automatically refresh when the repository changes outside twig")

            Spacer()

            // 显示提交数的下拉：用 menu 样式，更紧凑，符合 macOS HIG。
            Picker("Show", selection: Binding(
                get: { app.limit },
                set: { app.limit = $0; Task { await app.reloadGraphOnly() } }
            )) {
                Text("200 commits").tag(200)
                Text("500 commits").tag(500)
                Text("1000 commits").tag(1000)
                Text("3000 commits").tag(3000)
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
