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
                    ctx.fill(dot, with: .color(.init(nsColor: .windowBackgroundColor)))
                    ctx.stroke(dot, with: .color(dotColor), lineWidth: 3)
                } else {
                    ctx.fill(dot, with: .color(dotColor))
                    ctx.stroke(dot, with: .color(dotColor), lineWidth: 1)
                }
            }
            .frame(width: GraphMetrics.pad * 2 + CGFloat(graphWidth) * GraphMetrics.laneWidth)

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
                    Text(relativeDate(commit.timestamp))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .frame(height: GraphMetrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .background(backgroundColor)
    }

    // 行背景：选中 > 比较模式 from/to > hover > 透明。
    // 比较模式下 from 用稍深的蓝，to 用稍浅的蓝，跟 web 版 cmp-from/cmp-to 对应。
    private var backgroundColor: Color {
        if selected || compareFrom {
            return Color.accentColor.opacity(0.18)
        }
        if compareTo {
            return Color.accentColor.opacity(0.10)
        }
        if isHovered {
            return Color.primary.opacity(0.04)
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

    private func relativeDate(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// 图顶的"未提交改动"行：对应 web 版的 wipRow。
// 显示一个虚线圆圈 + "Uncommitted changes (N files)"，点击进入工作区视图。
struct WorkingCopyRow: View {
    @EnvironmentObject var app: AppState
    let fileCount: Int

    var body: some View {
        Button {
            Task { await app.showWorkingCopy() }
        } label: {
            HStack(spacing: 8) {
                // 虚线圆圈，跟 web 版一致。
                Canvas { ctx, size in
                    let center = CGPoint(x: GraphMetrics.laneX(0), y: size.height / 2)
                    let r = GraphMetrics.dotRadius
                    let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                    ctx.stroke(circle, with: .color(.secondary), style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                }
                .frame(width: GraphMetrics.pad * 2 + GraphMetrics.laneWidth)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Uncommitted changes (\(fileCount) file\(fileCount == 1 ? "" : "s"))")
                        .font(.body)
                        .foregroundStyle(.primary)
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
        }
        .buttonStyle(.plain)
        .listRowBackground(app.detailMode == .workingCopy ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

struct RefBadge: View {
    let ref: Ref

    var body: some View {
        Text(ref.name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .foregroundStyle(.white)
    }

    private var background: Color {
        switch ref.kind {
        case "head": return ref.isHead ? .accentColor : .green
        case "remote": return .orange
        default: return .purple
        }
    }
}
