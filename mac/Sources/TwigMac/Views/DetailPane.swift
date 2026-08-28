import SwiftUI

struct DetailPane: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.detailMode {
        case .none:
            ContentUnavailableView("Select a commit", systemImage: "doc.text.magnifyingglass")
        case .commit(let hash):
            if let d = app.commitDetail {
                HSplitView {
                    FileListView(
                        files: d.files,
                        selectedPath: app.selectedFile?.path,
                        header: shortHeader(hash: d.hash, subject: d.subject)
                    ) { f in Task { await app.selectFile(f, inCommit: hash) } }
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)
                    DiffPanelView()
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

    private func shortHeader(hash: String, subject: String) -> String {
        "\(String(hash.prefix(8)))  \(subject)"
    }

    private func plural(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
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
