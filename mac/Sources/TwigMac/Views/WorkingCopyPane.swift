import SwiftUI

struct WorkingCopyPane: View {
    @EnvironmentObject var app: AppState
    @State private var commitMessage = ""
    @State private var amend = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(
                    get: { app.selectedFile?.path },
                    set: { p in
                        guard let st = app.status else { return }
                        // conflicts 排在最前面，跟 web 版一致。
                        let all = st.staged + st.conflicts + st.unstaged
                        if let f = all.first(where: { $0.path == p }) {
                            Task { await app.selectWorkingCopyFile(f) }
                        }
                    }
                )) {
                    if let st = app.status {
                        Section {
                            ForEach(st.staged) { f in WorkingFileRow(f: f, staged: true).tag(f.path) }
                        } header: {
                            HStack {
                                Text("Staged").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if !st.staged.isEmpty {
                                    Button("Unstage all") {
                                        Task { await app.runOp(.init(action: "unstage"), label: "Unstage all") }
                                    }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
                                }
                            }
                        }

                        // 冲突文件单独一组，标红，用户一眼能看到。
                        if !st.conflicts.isEmpty {
                            Section {
                                ForEach(st.conflicts) { f in WorkingFileRow(f: f, staged: false, conflict: true).tag(f.path) }
                            } header: {
                                HStack {
                                    Text("Conflicts").font(.caption).foregroundStyle(.red)
                                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red)
                                }
                            }
                        }

                        Section {
                            ForEach(st.unstaged) { f in WorkingFileRow(f: f, staged: false).tag(f.path) }
                        } header: {
                            HStack {
                                Text("Unstaged").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if !st.unstaged.isEmpty {
                                    Button("Stage all") {
                                        Task { await app.runOp(.init(action: "stage"), label: "Stage all") }
                                    }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $commitMessage)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                    HStack {
                        Toggle("Amend", isOn: Binding(
                            get: { amend },
                            set: { newValue in
                                amend = newValue
                                // 勾上 amend 时把上一个提交的信息填进去，方便改。
                                // 对应 web 版 amendChk.onchange 里的逻辑。
                                if newValue && commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Task { await fillLastCommitMessage() }
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        Spacer()
                        Button("Commit") {
                            let msg = commitMessage
                            Task {
                                if await app.runOp(.init(action: "commit", message: msg, amend: amend), label: "Commit") {
                                    commitMessage = ""
                                    amend = false
                                }
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !amend)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            DiffPanelView()
        }
    }

    // 勾上 amend 时去拉上一个提交的 subject + body 填进输入框。
    private func fillLastCommitMessage() async {
        if let msg = await app.lastCommitMessage() {
            commitMessage = msg
        }
    }
}

private struct WorkingFileRow: View {
    @EnvironmentObject var app: AppState
    let f: FileChange
    let staged: Bool
    var conflict: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(statusChar)
                .font(.caption.monospaced().bold())
                .foregroundStyle(conflict ? .red : .orange)
                .frame(width: 14)
            Text((f.path as NSString).lastPathComponent).lineLimit(1)
            Spacer()
            if staged {
                Button("Unstage") {
                    Task { await app.runOp(.init(action: "unstage", paths: [f.path]), label: "Unstage \(f.path)") }
                }
                .font(.caption2).buttonStyle(.borderless)
            } else {
                Button("Stage") {
                    Task { await app.runOp(.init(action: "stage", paths: [f.path]), label: "Stage \(f.path)") }
                }
                .font(.caption2).buttonStyle(.borderless)
                if !conflict {
                    Button("Discard") {
                        Task { await app.discardFile(f.path, untracked: f.untracked) }
                    }
                    .font(.caption2).buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
        }
    }

    private var statusChar: String {
        if conflict { return "U" }
        let c = staged ? f.index : f.work
        return c.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : c
    }
}
