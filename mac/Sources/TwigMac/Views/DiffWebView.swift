import SwiftUI
import WebKit

// DiffWebView 内嵌一个 WKWebView 加载 /diff.html——这是"混合方案"的核心那一半：
// 侧边栏/工具栏/提交图/文件列表是原生的，diff 渲染那一块继续用现成的 diff2html
// （行内高亮、并排视图、语法着色、六条防误藏的注释正则……这些原生这边没有
// 等价的库，重写一遍不划算），Go 后端一个字节不用改。
struct DiffWebView: NSViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Coordinator 当 WKNavigationDelegate：页面加载完之后把之前记下的滚动位置滚回去。
    final class Coordinator: NSObject, WKNavigationDelegate {
        // 待恢复的纵向滚动位置；nil 表示这次加载不需要恢复（换文件/首次加载）。
        var pendingScrollY: CGFloat?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let y = pendingScrollY else { return }
            pendingScrollY = nil
            // diff.html 里 body 本身就是滚动容器，滚 window 即可；
            // split 视图的两栏同步滚动由 diff2html 的 synchronisedScroll 管。
            webView.evaluateJavaScript("window.scrollTo(0, \(y));")
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
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
        guard webView.url != url else { return }

        // 同一个文件切换 Unified/Split 或 Ignore 开关时，URL 会变、页面整体重载，
        // 重载完默认回到顶部，用户每次切视图都丢失阅读位置。网页版是原地重绘不重载，
        // 原生这边走 WKWebView 只能重载，就在重载前记下 scrollY、didFinish 里滚回去，
        // 达到同样的净效果。换文件时 SwiftUI 用 .id(path) 换了全新 WebView，
        // webView.url 为 nil，走下面的直接加载，不恢复位置。
        if webView.url != nil {
            webView.evaluateJavaScript("window.scrollY") { result, error in
                context.coordinator.pendingScrollY = (error == nil ? result as? Double : nil)
                    .map { CGFloat($0) }
                // 回调是异步的，加载放在回调里发起，保证"先记位置、再重载"的顺序。
                if webView.url != url { webView.load(URLRequest(url: url)) }
            }
        } else {
            context.coordinator.pendingScrollY = nil
            webView.load(URLRequest(url: url))
        }
    }
}
