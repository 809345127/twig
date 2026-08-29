import SwiftUI

// diff 内容本身交给内嵌的 WKWebView（DiffWebView）画，这里只放工具条：
// Unified/Split 切换、Ignore whitespace/comments 两个开关——跟网页版工具条
// 是同一套选项，只是原生控件更好看、跟系统主题走。
struct DiffPanelView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 整条工具条统一 caption 字号，跟图工具条、文件清单表头一致（网页版 diff-bar 也是 12px）。
            HStack(spacing: 14) {
                Picker("", selection: Binding(
                    get: { app.diffViewMode },
                    set: { app.diffViewMode = $0 }
                )) {
                    Text("Unified").tag(DiffViewMode.unified)
                    Text("Split").tag(DiffViewMode.split)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .labelsHidden()

                Toggle("Ignore whitespace", isOn: Binding(
                    get: { app.ignoreWhitespace },
                    set: { app.setIgnoreWhitespace($0) }
                )).toggleStyle(.checkbox)
                .fixedSize(horizontal: true, vertical: false)
                .help("Hide lines that differ only in whitespace — reindented blocks, tabs vs spaces, trailing spaces (git diff -b).")

                Toggle("Ignore comments", isOn: Binding(
                    get: { app.ignoreComments },
                    set: { app.setIgnoreComments($0) }
                )).toggleStyle(.checkbox)
                .fixedSize(horizontal: true, vertical: false)
                .help("Hide changes where every changed line is a comment (git diff -I). A comment change within 3 lines of a code change still shows — it falls inside git's context window.")

                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()

            if app.currentDiffRequest != nil {
                DiffWebView(url: app.diffPageURL)
                    .id(app.currentDiffRequest?.path)   // 换文件时强制换一个新的 WKWebView 状态锚点
            } else {
                Text("Select a file to see the changes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}
