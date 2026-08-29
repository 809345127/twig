import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            switch app.connection {
            case .connecting:
                ProgressView("Connecting to twig backend…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("Could not connect").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Retry") { Task { await app.connect() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                if app.repo != nil {
                    MainLayout()
                } else {
                    // 空仓库引导：别只摆一行灰字，直接告诉用户下一步是什么。
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                        Text("No repository open yet").font(.headline)
                        Button("Open Repository…") { app.openRepoPicker() }
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
