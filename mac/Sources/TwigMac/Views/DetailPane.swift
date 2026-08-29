import SwiftUI

struct DetailPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.detailMode {
        case .none:
            ContentUnavailableView("Select a commit", systemImage: "doc.text.magnifyingglass")
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
                    .padding(.horizontal, 8).padding(.vertical, 4)
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
                .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if files.isEmpty {
                Text("No files changed").font(.callout).foregroundStyle(.secondary).padding()
            } else {
                List(files, selection: Binding(get: { selectedPath }, set: { p in
                    if let f = files.first(where: { $0.path == p }) { onSelect(f) }
                })) { f in
                    FileRow(file: f).tag(f.path)
                }
                .listStyle(.plain)
            }
        }
    }
}

struct FileRow: View {
    let file: DiffFile

    var body: some View {
        HStack(spacing: 6) {
            Text(file.status)
                .font(.caption.monospaced().bold())
                .foregroundStyle(statusColor)
                .frame(width: 14)
            Text((file.path as NSString).lastPathComponent).lineLimit(1)
            Spacer()
            if !file.binary {
                if file.additions > 0 { Text("+\(file.additions)").font(.caption2).foregroundStyle(.green) }
                if file.deletions > 0 { Text("-\(file.deletions)").font(.caption2).foregroundStyle(.red) }
            } else {
                Text("bin").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .help(file.origPath.isEmpty ? file.path : "\(file.origPath) → \(file.path)")
    }

    private var statusColor: Color {
        switch file.status {
        case "A": return .green
        case "D": return .red
        case "R", "C": return .purple
        default: return .orange
        }
    }
}
