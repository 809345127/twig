import SwiftUI

struct CommitRowView: View {
    let commit: Commit
    let row: GraphGeometry.Row
    let graphWidth: Int
    let isHead: Bool
    var selected: Bool = false
    var compareFrom: Bool = false
    var compareTo: Bool = false

    @State private var isHovered = false

    // 比较模式下两端都算"选中"，只是端色条颜色不同。
    private var highlighted: Bool { selected || compareFrom || compareTo }

    var body: some View {
        HStack(spacing: 8) {
            Canvas { ctx, size in
                for seg in row.segments {
                    var path = Path()
                    path.move(to: point(lane: seg.fromLane, y: seg.fromY, height: size.height))
                    path.addLine(to: point(lane: seg.toLane, y: seg.toY, height: size.height))
                    ctx.stroke(path, with: .color(LaneColors.color(seg.color)),
                               style: StrokeStyle(lineWidth: seg.merge ? 1.5 : 2, lineCap: .round, lineJoin: .round))
                }
                let dotColor = LaneColors.color(row.dotColor)
                let center = point(lane: commit.lane, y: .mid, height: size.height)
                let r = row.isMerge ? GraphMetrics.dotRadius - 0.5 : GraphMetrics.dotRadius
                let dot = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                if isHead {
                    // 跟网页版一致：HEAD 是空心圆环，内部填窗口底色、外圈描 3pt 车道色。
                    ctx.fill(dot, with: .color(.init(nsColor: .windowBackgroundColor)))
                    ctx.stroke(dot, with: .color(dotColor), lineWidth: 3)
                } else {
                    ctx.fill(dot, with: .color(dotColor))
                    ctx.stroke(dot, with: .color(dotColor), lineWidth: 1)
                }
            }
            .frame(width: GraphMetrics.graphColumnWidth(lanes: graphWidth))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ForEach(commit.refs, id: \.fullName) { ref in
                        RefBadge(ref: ref)
                    }
                    Text(commit.subject)
                        .lineLimit(1)
                        .font(.body)
                        .fontWeight(isHead ? .semibold : .regular)
                }
                HStack(spacing: 5) {
                    Text(commit.authorName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·").foregroundStyle(.tertiary)
                    Text(commit.short)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(GraphDateFormat.string(commit.timestamp))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: GraphMetrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background(backgroundColor)
        // 比较模式两端各一条 3pt 端色条：起点（更早）灰色、终点强调色，
        // 跟网页版 .cmp-from / .cmp-to 的 inset 色条对应。
        .overlay(alignment: .leading) {
            if compareFrom {
                Rectangle().fill(Color.secondary).frame(width: 3)
            } else if compareTo {
                Rectangle().fill(Color.accentColor).frame(width: 3)
            }
        }
    }

    // 行背景：选中/比较两端 > hover > 透明。比较的两端用同一档底色，
    // 区别只在左侧端色条（跟网页版 .sel + cmp-from/cmp-to 的组合一致）。
    private var backgroundColor: Color {
        if highlighted {
            return Color.accentColor.opacity(0.18)
        }
        if isHovered {
            return Color.primary.opacity(0.05)
        }
        return Color.clear
    }

    private func point(lane: Int, y: GraphGeometry.EdgeY, height: CGFloat) -> CGPoint {
        let x = GraphMetrics.laneX(lane)
        switch y {
        case .top: return CGPoint(x: x, y: 0)
        case .mid: return CGPoint(x: x, y: height / 2)
        case .bottom: return CGPoint(x: x, y: height)
        }
    }
}

// 提交图行的日期格式跟网页版 fmtDate 逐个对齐（界面一律英文，月份固定英文缩写）：
// 今天 → "Today 14:32"，昨天 → "Yesterday 09:15"，今年 → "Aug 28, 14:32"，
// 更早 → "Aug 28, 2025"。formatter 初始化不便宜，图上几百行共享这几个静态实例。
enum GraphDateFormat {
    private static let todayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'Today' HH:mm"; return f
    }()
    private static let yesterdayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "'Yesterday' HH:mm"; return f
    }()
    private static let thisYearFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"; return f
    }()
    private static let olderFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static let calendar = Calendar(identifier: .gregorian)

    static func string(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let now = Date()
        if calendar.isDateInToday(date) { return todayFmt.string(from: date) }
        if calendar.isDateInYesterday(date) { return yesterdayFmt.string(from: date) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear ? thisYearFmt.string(from: date) : olderFmt.string(from: date)
    }
}

// 图顶的"未提交改动"行：对应 web 版的 wipRow。
// 显示一个虚线圆圈 + "Uncommitted changes (N files)"，点击进入工作区视图。
struct WorkingCopyRow: View {
    @EnvironmentObject var app: AppState
    let fileCount: Int
    let graphWidth: Int   // 跟提交行同一个图列宽度，文字列才能对齐（之前只按 1 条轨道算，错位）
    @State private var isHovered = false

    private var selected: Bool { app.detailMode == .workingCopy }

    var body: some View {
        Button {
            Task { await app.showWorkingCopy() }
        } label: {
            HStack(spacing: 8) {
                // 虚线圆圈，跟 web 版一致。画布的宽度跟提交行一致（同一个图列宽），
                // 这行的文字才会跟下面所有提交的 subject 垂直对齐。
                Canvas { ctx, size in
                    let center = CGPoint(x: GraphMetrics.laneX(0), y: size.height / 2)
                    let r = GraphMetrics.dotRadius
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    ctx.stroke(circle, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                }
                .frame(width: GraphMetrics.graphColumnWidth(lanes: graphWidth))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uncommitted changes (\(fileCount) file\(fileCount == 1 ? "" : "s"))")
                        .font(.body)
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .fontWeight(selected ? .semibold : .regular)
                    Text("working copy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .frame(height: GraphMetrics.rowHeight)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        // 选中背景直接画在行内（跟 CommitRowView 同一档透明度），
        // listRowBackground 留空，避免两层底色叠加。
        .listRowBackground(Color.clear)
    }

    private var rowBackground: Color {
        if selected { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

// 分支 / tag 徽章：配色跟网页版 .reftag 对齐——
// 当前分支实心强调色白字；其余本地分支浅强调色底+强调字+描边；
// 远程分支中性灰；tag 柔和琥珀。不用之前那种绿/橙/紫实心胶囊。
//
// 分支徽章（本地/远程）可点击：点一下把图筛成只显示这条分支——这是 twig
// "逐条勾选分支"核心能力的最近入口，不用回侧边栏几十个复选框里找。
// tag 不可筛（侧边栏 tag 行也没有复选框），点击无效果。
struct RefBadge: View {
    @EnvironmentObject var app: AppState
    let ref: Ref

    private var filterable: Bool { ref.kind == "head" || ref.kind == "remote" }

    var body: some View {
        Button {
            if filterable { app.showOnlyRef(ref.fullName) }
        } label: {
            Text(ref.name)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(background, in: Capsule())
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
                .foregroundStyle(foreground)
        }
        .buttonStyle(.plain)
        .help(filterable ? "Show only \(ref.name) in graph" : ref.fullName)
    }

    private var background: Color {
        switch ref.kind {
        case "head": return ref.isHead ? .accentColor : Color.accentColor.opacity(0.14)
        case "remote": return Color.primary.opacity(0.06)
        default: return Color.orange.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch ref.kind {
        case "head": return ref.isHead ? .white : .accentColor
        case "remote": return .secondary
        default: return .orange
        }
    }

    private var border: Color {
        switch ref.kind {
        case "head": return ref.isHead ? .clear : Color.accentColor.opacity(0.5)
        case "remote": return Color(nsColor: .separatorColor)
        default: return Color.orange.opacity(0.4)
        }
    }
}
