import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var app: AppState

    var heads: [Ref] { app.refs.filter { $0.kind == "head" } }
    var remotes: [Ref] { app.refs.filter { $0.kind == "remote" } }
    var tags: [Ref] { app.refs.filter { $0.kind == "tag" } }

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
                            Text("\(st.staged.count + st.unstaged.count)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(app.detailMode == .workingCopy ? Color.accentColor.opacity(0.15) : nil)
            }

            Section("Branches") {
                ForEach(heads, id: \.fullName) { ref in
                    RefRow(ref: ref, checked: app.selectedRefs.contains(ref.fullName)) {
                        app.toggleRef(ref.fullName)
                    }
                }
            }

            if !remotes.isEmpty {
                Section("Remote Branches") {
                    ForEach(remotes, id: \.fullName) { ref in
                        RefRow(ref: ref, checked: app.selectedRefs.contains(ref.fullName)) {
                            app.toggleRef(ref.fullName)
                        }
                    }
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    ForEach(tags, id: \.fullName) { ref in
                        Label(ref.name, systemImage: "tag")
                            .font(.callout)
                    }
                }
            }

            if !app.stashes.isEmpty {
                Section("Stashes") {
                    ForEach(app.stashes) { s in
                        Text(s.subject).font(.callout).lineLimit(1)
                    }
                }
            }

            if !app.recent.isEmpty {
                Section("Recent") {
                    ForEach(app.recent, id: \.self) { p in
                        Button {
                            Task { await app.openRepo(p) }
                        } label: {
                            Text((p as NSString).lastPathComponent).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
                Text(ref.name).lineLimit(1)
                if ref.isHead {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.caption2).foregroundStyle(.blue)
                }
                Spacer()
                if ref.ahead > 0 || ref.behind > 0 {
                    Text("↑\(ref.ahead) ↓\(ref.behind)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
