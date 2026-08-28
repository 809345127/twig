import SwiftUI

// 跟 web/app.js 的 COLORS 数组逐个对齐，同一条分支链在原生版和浏览器版看起来
// 是同一个颜色，用户来回切换时不会觉得"这是另一套东西"。
enum LaneColors {
    static let hex: [String] = [
        "#2f6feb", "#1a7f37", "#bf3989", "#9a6700", "#6639ba",
        "#0f7c8c", "#cf222e", "#7a6a00", "#0969da", "#8250df",
    ]

    static func color(_ index: Int) -> Color {
        let i = ((index % hex.count) + hex.count) % hex.count
        return Color(hex: hex[i])
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
