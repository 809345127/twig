import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    @State private var branchFilter: String = ""

    // 分组折叠状态：Branches/Stashes 默认展开（常用且通常不多），
    // Remote Branches/Tags 默认折叠（colt 这种仓库几百个 tag，全列出来要滚半天）。
    @State private var branchesExpanded = true
    @State private var remotesExpanded = false
    @State private var tagsExpanded = false
    @State private var stashesExpanded = true

    var heads: [Ref] { filterRefs(app.refs.filter { $0.kind == "head" }) }
    var remotes: [Ref] { filterRefs(app.refs.filter { $0.kind == "remote" }) }
    var tags: [Ref] { filterRefs(app.refs.filter { $0.kind == "tag" }) }

    private func filterRefs(_ refs: [Ref]) -> [Ref] {
        let f = branchFilter.lowercased()
        return f.isEmpty ? refs : refs.filter { $0.name.lowercased().contains(f) }
    }

    var body: some View {
        List {
            Section("Working Copy") {
                Button {
                    Task { await app.showWorkingCopy() }
                } label: {
                    HStack {
                        Image(systemName: "circle.dashed")
                        Text("Working Copy")
                        Spacer()
                        if let st = app.status, !st.clean {
                            Text("\(st.staged.count + st.unstaged.count + st.conflicts.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(app.detailMode == .workingCopy ? Color.accentColor.opacity(0.18) : nil)
            }

            // "Recent" 放在这里、紧跟 Working Copy 之后——它跟"当前这个仓库"无关，是切去
            // 别的仓库用的。之前排在 Tags/Stashes 后面，分支多的仓库要滚几百行才翻得到。
            if !app.recent.isEmpty {
                Section("Recent") {
                    ForEach(app.recent, id: \.self) { p in
                        HStack {
                            Button {
                                Task { await app.openRepo(p) }
                            } label: {
                                Text((p as NSString).lastPathComponent).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button {
                                Task { await app.forgetRepo(p) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from recent list")
                        }
                    }
                }
            }

            // Branches：可折叠，标题显示分支数，右侧保留快捷筛选按钮。
            Button {
                withAnimation { branchesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: branchesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    // 标题样式对齐真正的 Section 标题（11pt 加粗次要色），
                    // 不然自定义折叠标题是正文字号，比上面的 "Working Copy" 还显眼。
                    Text("Branches").sectionHeaderFont
                    Text("(\(heads.count))").sectionHeaderFont
                    Spacer()
                    Button("All") {
                        app.selectedRefs = Set(app.refs.filter { $0.kind == "head" }.map { $0.fullName })
                        Task { await app.reloadGraphOnly() }
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                    Button("None") {
                        app.selectedRefs = []
                        Task { await app.reloadGraphOnly() }
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                    Button("Current") {
                        if let cur = app.refs.first(where: { $0.kind == "head" && $0.isHead }) {
                            app.selectedRefs = [cur.fullName]
                            Task { await app.reloadGraphOnly() }
                        }
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Color.accentColor)
                    Button {
                        if let r = app.askInput(title: "New Branch", message: "Starting from the current HEAD",
                                                 placeholder: "feature/my-branch",
                                                 checkboxLabel: "Check out after creating", checkboxChecked: true) {
                            Task { await app.runOp(.init(action: "createBranch", name: r.value,
                                                          startPoint: "HEAD", checkout: r.checked),
                                                    label: "Create branch \(r.value)") }
                        }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("New branch")
                }
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))

            if branchesExpanded {
                ForEach(heads, id: \.fullName) { ref in
                    RefRow(ref: ref, checked: app.selectedRefs.contains(ref.fullName)) {
                        app.toggleRef(ref.fullName)
                    }
                    .contextMenu { refContextMenu(ref) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                }
            }

            if !remotes.isEmpty {
                Button {
                    withAnimation { remotesExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: remotesExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Remote Branches").sectionHeaderFont
                        Text("(\(remotes.count))").sectionHeaderFont
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))

                if remotesExpanded {
                    ForEach(remotes, id: \.fullName) { ref in
                        RefRow(ref: ref, checked: app.selectedRefs.contains(ref.fullName)) {
                            app.toggleRef(ref.fullName)
                        }
                        .contextMenu { refContextMenu(ref) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                    }
                }
            }

            if !tags.isEmpty {
                Button {
                    withAnimation { tagsExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tagsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("Tags").sectionHeaderFont
                        Text("(\(tags.count))").sectionHeaderFont
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))

                if tagsExpanded {
                    ForEach(tags, id: \.fullName) { ref in
                        Button {
                            locateInGraph(ref.hash)
                        } label: {
                            Label(ref.name, systemImage: "tag")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Checkout tag \(ref.name)") {
                                Task { await app.checkoutRef(ref) }
                            }
                            Button("Locate in graph") { locateInGraph(ref.hash) }
                            Divider()
                            Button("Copy tag name") { app.copyToClipboard(ref.name) }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                    }
                }
            }

            // Stashes：可折叠，标题右侧保留 + 按钮。
            Button {
                withAnimation { stashesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: stashesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Stashes").sectionHeaderFont
                    Text("(\(app.stashes.count))").sectionHeaderFont
                    Spacer()
                    Button {
                        if app.status?.clean ?? true {
                            app.setStatus("Working copy is clean — nothing to stash", kind: "err")
                            return
                        }
                        if let r = app.askInput(title: "Stash Changes",
                                                 message: "Put the current uncommitted changes aside.",
                                                 placeholder: "Message (optional)",
                                                 checkboxLabel: "Include untracked files", checkboxChecked: true) {
                            Task { await app.runOp(.init(action: "stashPush", message: r.value,
                                                          includeUntracked: r.checked), label: "Stash") }
                        }
                    } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Stash changes")
                }
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))

            if stashesExpanded {
                ForEach(app.stashes) { s in
                    Text(s.subject).font(.callout).lineLimit(1)
                        .contextMenu {
                            Text(s.subject).font(.caption).foregroundStyle(.secondary)
                            Button("Pop (apply and drop)") {
                                Task { await app.runOp(.init(action: "stashApply", ref: s.ref, drop: true),
                                                        label: "Pop stash") }
                            }
                            Button("Apply (keep the stash)") {
                                Task { await app.runOp(.init(action: "stashApply", ref: s.ref, drop: false),
                                                        label: "Apply stash") }
                            }
                            Divider()
                            Button("Drop this stash", role: .destructive) {
                                if app.confirm(title: "Drop stash", message: "Drop stash \"\(s.subject)\"?\nThis cannot be undone.",
                                               buttonTitle: "Drop", destructive: true) {
                                    Task { await app.runOp(.init(action: "stashDrop", ref: s.ref), label: "Drop stash") }
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                }
            }
        }
        .listStyle(.sidebar)
        // 隐藏 List 默认的滚动内容背景，透出外面统一的窗口背景色，
        // 避免侧边栏出现和主内容区不一致的灰色。
        .scrollContentBackground(.hidden)
        .searchable(text: $branchFilter, prompt: "Filter branches")
    }

    // 在图上定位到某个 ref 指向的提交：选中它、详情面板显示它，并把那一行滚到图区中央。
    private func locateInGraph(_ hash: String) {
        guard let commits = app.graph?.commits, commits.contains(where: { $0.hash == hash }) else {
            app.setStatus("This ref is not on the graph (not checked, or beyond the shown commit count)", kind: "err")
            return
        }
        app.requestGraphScroll(hash)
        Task { await app.selectCommit(hash) }
    }

    // 分支右键菜单：对应 web 的 showRefMenu。
    @ViewBuilder
    private func refContextMenu(_ ref: Ref) -> some View {
        Text(ref.name).font(.caption).foregroundStyle(.secondary)
        let isCurrent = ref.kind == "head" && app.head?.hash == ref.hash && !(app.head?.detached ?? true)
        if !isCurrent {
            Button("Checkout") { Task { await app.checkoutRef(ref) } }
        }
        Button("Locate in graph") { locateInGraph(ref.hash) }
        Divider()
        Button("Show only this in graph") {
            app.selectedRefs = [ref.fullName]
            Task { await app.reloadGraphOnly() }
        }
        if app.selectedRefs.contains(ref.fullName) {
            Button("Uncheck (remove from graph)") {
                app.selectedRefs.remove(ref.fullName)
                Task { await app.reloadGraphOnly() }
            }
        } else {
            Button("Check (add to graph)") {
                app.selectedRefs.insert(ref.fullName)
                Task { await app.reloadGraphOnly() }
            }
        }
        if !isCurrent && ref.kind != "tag" {
            Divider()
            Button("Merge \(ref.name) into current branch") {
                Task { await app.runOp(.init(action: "merge", target: ref.name), label: "Merge \(ref.name)") }
            }
            Button("Rebase current branch onto \(ref.name)") {
                Task { await app.runOp(.init(action: "rebase", target: ref.name), label: "Rebase onto \(ref.name)") }
            }
        }
        Divider()
        Button("Copy branch name") { app.copyToClipboard(ref.name) }
        if ref.kind == "head" && !isCurrent {
            Divider()
            Button("Delete local branch", role: .destructive) {
                Task { await app.deleteBranch(ref.name) }
            }
        }
        if ref.kind == "remote" {
            Divider()
            Button("Delete remote branch", role: .destructive) {
                Task { await app.deleteRemoteBranch(ref.name) }
            }
        }
    }
}

private struct RefRow: View {
    let ref: Ref
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? Color.accentColor : .secondary)
                // 当前分支加粗——几十条分支里一眼定位，SourceTree 同款惯例。
                Text(ref.name).lineLimit(1)
                    .fontWeight(ref.isHead ? .semibold : .regular)
                if ref.isHead {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption2).foregroundStyle(Color.accentColor)
                }
                Spacer()
                if ref.ahead > 0 || ref.behind > 0 {
                    Text("↑\(ref.ahead) ↓\(ref.behind)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 跟网页版复选框的 title 同一句话："都不勾"不是"都不画"，而是"画全部"。
        .help("When anything is checked, the graph draws only checked branches")
    }
}

// 自定义折叠分组标题统一用这套字号字重，视觉上对齐系统 Section 的小标题。
private extension View {
    var sectionHeaderFont: some View {
        self.font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
