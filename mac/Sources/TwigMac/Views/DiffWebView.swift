import SwiftUI
import WebKit

// DiffWebView 内嵌一个 WKWebView 加载 /diff.html——这是"混合方案"的核心那一半：
// 侧边栏/工具栏/提交图/文件列表是原生的，diff 渲染那一块继续用现成的 diff2html
// （行内高亮、并排视图、语法着色、六条防误藏的注释正则……这些原生这边没有
// 等价的库，重写一遍不划算），Go 后端一个字节不用改。
struct DiffWebView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        // 页面自己的 CSS（style.css 的 :root 变量）已经处理了深浅色，
        // 这里把 WKWebView 自身的底色也设成透明，避免加载瞬间闪一下系统默认的白。
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard let url else {
            if webView.url != nil { webView.loadHTMLString("", baseURL: nil) }
            return
        }
        // 只在地址真的变了的时候才重新加载——SwiftUI 视图刷新很频繁，
        // 每次都 load() 会打断用户在页面里的滚动位置、还白白重发一次网络请求。
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }
}
