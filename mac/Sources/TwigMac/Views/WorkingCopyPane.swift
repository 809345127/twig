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
                        if let f = (st.staged + st.unstaged).first(where: { $0.path == p }) {
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
                                    Button("Unstage all") { Task { await app.runOp(.init(action: "unstage")) } }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(.blue)
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
                                    Button("Stage all") { Task { await app.runOp(.init(action: "stage")) } }
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
                        Toggle("Amend", isOn: $amend).toggleStyle(.checkbox)
                        Spacer()
                        Button("Commit") {
                            let msg = commitMessage
                            Task {
                                if await app.runOp(.init(action: "commit", message: msg, amend: amend)) {
                                    commitMessage = ""
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
}

private struct WorkingFileRow: View {
    @EnvironmentObject var app: AppState
    let f: FileChange
    let staged: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(statusChar).font(.caption.monospaced().bold()).foregroundStyle(.orange).frame(width: 14)
            Text((f.path as NSString).lastPathComponent).lineLimit(1)
            Spacer()
            Button(staged ? "Unstage" : "Stage") {
                Task {
                    if staged { await app.runOp(.init(action: "unstage", paths: [f.path])) }
                    else { await app.runOp(.init(action: "stage", paths: [f.path])) }
                }
            }
            .font(.caption2).buttonStyle(.borderless)
        }
    }

    private var statusChar: String {
        let c = staged ? f.index : f.work
        return c.trimmingCharacters(in: .whitespaces).isEmpty ? "?" : c
    }
}
