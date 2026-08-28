import SwiftUI

// v1 用等宽文本 + 逐行着色渲染 patch，先把端到端链路跑通。
// 网页版那套行内高亮 / 左右并排 / 语法着色是 diff2html 白送的，原生这边
// 没有等价的现成库；后续打算内嵌一个 WKWebView 复用同一份 vendor 资源
// （见交接文档"混合方案"），这里先占位。
struct DiffPanelView: View {
    @EnvironmentObject var app: AppState

    var lines: [DiffLine] {
        parsePatch(app.diffPatch)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Toggle("Ignore whitespace", isOn: Binding(
                    get: { app.ignoreWhitespace },
                    set: { app.setIgnoreWhitespace($0) }
                )).toggleStyle(.checkbox)
                Toggle("Ignore comments", isOn: Binding(
                    get: { app.ignoreComments },
                    set: { app.setIgnoreComments($0) }
                )).toggleStyle(.checkbox)
                Spacer()
                if app.diffTruncated {
                    Label("Truncated", systemImage: "scissors").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if let err = app.diffError {
                Text(err).foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if lines.isEmpty {
                Text(app.diffPatch.isEmpty ? "No changes to show." : "")
                    .foregroundStyle(.secondary).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.kind.foreground)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.kind.background)
                        }
                    }
                }
            }
        }
    }
}

struct DiffLine {
    enum Kind {
        case add, remove, hunk, meta, context
        var foreground: Color {
            switch self {
            case .add: return .green
            case .remove: return .red
            case .hunk: return .blue
            case .meta: return .secondary
            case .context: return .primary
            }
        }
        var background: Color {
            switch self {
            case .add: return .green.opacity(0.08)
            case .remove: return .red.opacity(0.08)
            default: return .clear
            }
        }
    }
    let text: String
    let kind: Kind
}

func parsePatch(_ patch: String) -> [DiffLine] {
    guard !patch.isEmpty else { return [] }
    var out: [DiffLine] = []
    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") ||
            line.hasPrefix("--- ") || line.hasPrefix("+++ ") ||
            line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") ||
            line.hasPrefix("similarity index") || line.hasPrefix("rename from") || line.hasPrefix("rename to") {
            out.append(.init(text: line, kind: .meta))
        } else if line.hasPrefix("@@") {
            out.append(.init(text: line, kind: .hunk))
        } else if line.hasPrefix("+") {
            out.append(.init(text: line, kind: .add))
        } else if line.hasPrefix("-") {
            out.append(.init(text: line, kind: .remove))
        } else {
            out.append(.init(text: line, kind: .context))
        }
    }
    return out
}
