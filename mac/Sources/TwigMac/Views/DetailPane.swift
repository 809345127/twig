import SwiftUI

struct DetailPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            switch app.detailMode {
            case .none:
                // ⚠️ ContentUnavailableView 不会自己撑满可用空间，只按文字理想宽度
                // 渲染——不套这个 frame 的话，空态会把整条 VSplitView/HSplitView 的
                // 理想宽度拖垮，整个窗口内容收缩成一条居中的窄带（2026-08-29 实测）。
                ContentUnavailableView("Select a commit", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .commit(let hash):
                if let d = app.commitDetail {
                    VStack(spacing: 0) {
                        CommitMetaHeader(detail: d)
                        Divider()
                        HSplitView {
                            FileListView(
                                files: d.files,
                                selectedPath: app.selectedFile?.path,
                                header: d.files.isEmpty ? "(this commit changes no files)" : "\(plural(d.files.count)) changed"
                            ) { f in Task { await app.selectFile(f, inCommit: hash) } }
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                            DiffPanelView()
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .compare(let from, let to):
                if let d = app.rangeDetail {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("\(String(from.prefix(8))) → \(String(to.prefix(8)))")
                                .font(.caption).foregroundStyle(.secondary)
                            if d.behind > 0 && d.ahead > 0 {
                                Text("diverged \(d.behind) / \(d.ahead)").font(.caption2).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                Task { await app.loadCompare(from: to, to: from) }
                            } label: {
                                Label("Swap", systemImage: "arrow.left.arrow.right")
                            }
                            .buttonStyle(.borderless).font(.caption)
                            Button("Exit compare") {
                                Task { await app.selectCommit(to) }
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                        Divider()
                        HSplitView {
                            FileListView(
                                files: d.files,
                                selectedPath: app.selectedFile?.path,
                                header: d.files.isEmpty ? "These two versions are identical" : "\(plural(d.files.count)) changed"
                            ) { f in Task { await app.selectFile(f, inRange: (from, to)) } }
                            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                            DiffPanelView()
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .workingCopy:
                WorkingCopyPane()
            }
        }
        // 故意不加切换动画：detailMode 在逐行浏览提交时也会变（关联值是 hash），
        // 每点一行都淡入淡出会发"粘"；模式切换（进/出比较、工作区）直接呈现更跟手。
    }

    private func plural(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}

// 提交详情顶部的元数据区：subject / author / date / hash / parents / body。
// 对应 web 的 renderCommitDetail 里 dSubject / dMeta / dBody 那三块。
struct CommitMetaHeader: View {
    let detail: CommitDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(detail.subject)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 12) {
                Label(detail.authorName, systemImage: "person")
                Label(formattedDate, systemImage: "clock")
                Label(detail.short, systemImage: "number")
                    .font(.system(.caption, design: .monospaced))
                if detail.parents.count > 1 {
                    Label("\(detail.parents.count) parents", systemImage: "arrow.triangle.merge")
                } else if let p = detail.parents.first {
                    Label(String(p.prefix(8)), systemImage: "arrow.left")
                        .font(.system(.caption, design: .monospaced))
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !detail.body.isEmpty {
                Text(detail.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedDate: String {
        let date = Date(timeIntervalSince1970: TimeInterval(detail.timestamp))
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

struct FileListView: View {
    let files: [DiffFile]
    let selectedPath: String?
    let header: String
    let onSelect: (DiffFile) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(header).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            Divider()
            if files.isEmpty {
                Text("No files changed").font(.callout).foregroundStyle(.secondary).padding()
            } else {
                List(files, selection: Binding(get: { selectedPath }, set: { p in
                    if let f = files.first(where: { $0.path == p }) { onSelect(f) }
                })) { f in
                    FileRow(file: f).tag(f.path)
                }
                // 用 .plain 并藏掉 List 默认背景：文件清单在内容区里，不是侧边栏，
                // .sidebar 样式会带一层灰色 material，跟统一后的窗口底色不一致。
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct FileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 6) {
            FileStatusBadge(status: file.status)
            // 显示完整路径（网页版也显示全路径）：目录部分用三级前景色弱化，
            // 空间不够时优先压缩目录，文件名始终完整可见。
            FilePathText(path: file.path)
            Spacer(minLength: 4)
            if !file.binary {
                if file.additions > 0 { Text("+\(file.additions)").font(.caption2.monospaced()).foregroundStyle(.green) }
                if file.deletions > 0 { Text("-\(file.deletions)").font(.caption2.monospaced()).foregroundStyle(.red) }
            } else {
                Text("bin").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .help(file.origPath.isEmpty ? file.path : "\(file.origPath) → \(file.path)")
    }
}

// 文件状态小色块：白字 + 固定底色 + 3pt 圆角，颜色跟网页版 .st.A/.M/.D/... 逐个对齐，
// 两个产品线看起来是同一套状态语言。
struct FileStatusBadge: View {
    let status: String

    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(background, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var background: Color {
        switch status {
        case "A": return Color(hex: "#1a7f37")
        case "M": return Color(hex: "#9a6700")
        case "D": return Color(hex: "#cf222e")
        case "R": return Color(hex: "#6639ba")
        case "C": return Color(hex: "#0969da")
        case "U": return Color(hex: "#bf3989")
        default: return Color.secondary
        }
    }
}

// 文件路径文本：目录段三级灰、文件名一级色，单行显示；
// 窄的时候目录段先被截断（layoutPriority 让文件名保住）。
struct FilePathText: View {
    let path: String

    var body: some View {
        let ns = path as NSString
        let name = ns.lastPathComponent
        let dir = ns.deletingLastPathComponent
        HStack(spacing: 0) {
            if dir != "." && !dir.isEmpty {
                Text(dir + "/")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
            }
            Text(name).lineLimit(1)
        }
        .font(.callout)
    }
}
