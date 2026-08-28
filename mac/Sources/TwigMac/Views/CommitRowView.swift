import SwiftUI

struct CommitRowView: View {
    let commit: Commit
    let row: GraphGeometry.Row
    let graphWidth: Int
    let isHead: Bool

    var body: some View {
        HStack(spacing: 8) {
            Canvas { ctx, size in
                for seg in row.segments {
                    var path = Path()
                    path.move(to: point(lane: seg.fromLane, y: seg.fromY, height: size.height))
                    path.addLine(to: point(lane: seg.toLane, y: seg.toY, height: size.height))
                    ctx.stroke(path, with: .color(LaneColors.color(seg.color)),
                               style: StrokeStyle(lineWidth: seg.merge ? 1.5 : 2, lineCap: .round))
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

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    ForEach(commit.refs, id: \.fullName) { ref in
                        RefBadge(ref: ref)
                    }
                    Text(commit.subject)
                        .lineLimit(1)
                        .fontWeight(isHead ? .semibold : .regular)
                }
                HStack(spacing: 6) {
                    Text(commit.authorName).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(commit.short).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(relativeDate(commit.timestamp)).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(height: GraphMetrics.rowHeight)
        .contentShape(Rectangle())
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

struct RefBadge: View {
    let ref: Ref

    var body: some View {
        Text(ref.name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
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
