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
                            // 空组给个占位，跟网页版 renderWip 的 "(empty)" 一致。
                            if st.staged.isEmpty {
                                Text("(empty)").font(.callout).foregroundStyle(.tertiary)
                            } else {
                                ForEach(st.staged) { f in WorkingFileRow(f: f, staged: true).tag(f.path) }
                            }
                        } header: {
                            HStack {
                                Text("Staged").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if !st.staged.isEmpty {
                                    Button("Unstage all") {
                                        Task { await app.runOp(.init(action: "unstage"), label: "Unstage all") }
                                    }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
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
                            if st.unstaged.isEmpty {
                                Text("(empty)").font(.callout).foregroundStyle(.tertiary)
                            } else {
                                ForEach(st.unstaged) { f in WorkingFileRow(f: f, staged: false).tag(f.path) }
                            }
                        } header: {
                            HStack {
                                Text("Unstaged").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                if !st.unstaged.isEmpty {
                                    Button("Stage all") {
                                        Task { await app.runOp(.init(action: "stage"), label: "Stage all") }
                                    }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
                // 同 DetailPane 的文件清单：内容区里用 .plain，避免 .sidebar 的灰底。
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    // ZStack 叠一层占位文字：TextEditor 原生没有 placeholder。
                    ZStack(alignment: .topLeading) {
                        if commitMessage.isEmpty {
                            Text("Describe your changes…  (⌘↵ to commit)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $commitMessage)
                            .font(.system(.body, design: .monospaced))
                    }
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
            // 状态色块跟提交详情文件清单、网页版同一套。
            FileStatusBadge(status: statusChar)
            FilePathText(path: f.path)
            Spacer(minLength: 4)
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
        // 双击 = stage/unstage 切换，不用瞄准行尾的小字按钮。
        .onTapGesture(count: 2) {
            Task {
                if staged {
                    await app.runOp(.init(action: "unstage", paths: [f.path]), label: "Unstage \(f.path)")
                } else if !conflict {
                    await app.runOp(.init(action: "stage", paths: [f.path]), label: "Stage \(f.path)")
                }
            }
        }
        // Mac 应用的桌上赌注：Reveal in Finder / 打开 / 复制路径。
        .contextMenu {
            Button("Open") { app.openFile(f.path) }
            Button("Reveal in Finder") { app.revealInFinder(f.path) }
            Divider()
            Button("Copy Path") { app.copyFilePath(f.path) }
            Button("Copy Relative Path") { app.copyToClipboard(f.path) }
        }
    }

    private var statusChar: String {
        // 跟网页版 renderWip 同一个映射：冲突 U、未跟踪按新增 A，其余取 git 状态字母。
        if conflict { return "U" }
        if f.untracked { return "A" }
        let c = staged ? f.index : f.work
        let trimmed = c.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "A" : trimmed
    }
}
