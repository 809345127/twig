import SwiftUI

struct RepoToolbar: ToolbarContent {
    @EnvironmentObject var app: AppState

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(app.repo?.name ?? "").font(.headline)
                if let h = app.head {
                    Text(h.detached ? "detached @ \(String(h.hash.prefix(8)))" : h.branch)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItemGroup {
            Button { Task { await app.runOp(.init(action: "fetch")) } } label: {
                Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { Task { await app.runOp(.init(action: "pull")) } } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            Button { Task { await app.runOp(.init(action: "push")) } } label: {
                Label("Push", systemImage: "arrow.up.circle")
            }
            Divider()
            Button { Task { await app.refreshAll() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(app.busy)
        }
    }
}
