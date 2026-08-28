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
                    Text("No repository open yet")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
