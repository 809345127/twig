import Foundation

// GraphGeometry 把后端算好的 Graph（提交-轨道分配、连线的起止轨道）预处理成
// "每一行要画什么线段"，好让 GraphPane 用原生 List 逐行渲染——
// 这是原生版相对网页版最直接的一个优势：List 只画看得见的那几行，
// 3000 条提交也不会卡（网页版这里要建 3000 个 DOM 行 + 上万个 SVG 节点，实测 976ms）。
//
// 线的画法比网页版简化了一点：网页版隔一行的连线会拐两次画成一条贝塞尔曲线，
// 这里为了让每一行能独立算出自己的线段（不依赖前后行），改成直线转折——
// 视觉上是同一种"之字形"分叉图，只是转角是尖的不是圆的。以后想要弧线，
// 在 Segment 里加一个曲率字段、Canvas 画 quadCurve 就行，行级预处理这层不用动。
struct GraphGeometry {
    // 一段线：从 (fromLane, fromEdgeY) 到 (toLane, toEdgeY)，颜色和是否为合并线。
    // fromEdgeY / toEdgeY 用 0 表示行顶、1 表示行中、2 表示行底，具体像素值由渲染层决定。
    struct Segment {
        let fromLane: Int
        let fromY: EdgeY
        let toLane: Int
        let toY: EdgeY
        let color: Int
        let merge: Bool
    }
    enum EdgeY { case top, mid, bottom }

    struct Row {
        var segments: [Segment] = []
        var dotColor: Int = 0
        var isMerge: Bool = false
    }

    let rows: [Row]
    let laneWidth: Int   // 轨道总数，前端据此定图区宽度

    init(graph: Graph) {
        var rows = Array(repeating: Row(), count: graph.commits.count)

        for e in graph.edges {
            // 起点所在行：从提交的轨道，画到中间轨道，落在行底。
            if e.fromRow < rows.count {
                rows[e.fromRow].segments.append(
                    .init(fromLane: e.fromLane, fromY: .mid, toLane: e.lane, toY: .bottom, color: e.color, merge: e.merge))
            }
            // 终点所在行：从行顶的中间轨道，画到提交的轨道。
            if e.toRow < rows.count && e.toRow >= 0 {
                rows[e.toRow].segments.append(
                    .init(fromLane: e.lane, fromY: .top, toLane: e.toLane, toY: .mid, color: e.color, merge: e.merge))
            }
            // 中间跨过的整行：贯穿的竖线。
            if e.toRow - e.fromRow > 1 {
                for r in (e.fromRow + 1)..<e.toRow where r >= 0 && r < rows.count {
                    rows[r].segments.append(
                        .init(fromLane: e.lane, fromY: .top, toLane: e.lane, toY: .bottom, color: e.color, merge: e.merge))
                }
            }
        }

        // colorOfCommit：先找"从这行出发的非合并线"的颜色，没有就找"到这行为止的线"，
        // 都没有（比如没有父提交的根提交）就退到它自己的轨道号。跟 app.js 的
        // colorOfCommit 是同一套优先级。
        for (row, commit) in graph.commits.enumerated() {
            let outgoing = graph.edges.first { $0.fromRow == row && !$0.merge }
            let incoming = graph.edges.first { $0.toRow == row }
            rows[row].dotColor = outgoing?.color ?? incoming?.color ?? commit.lane
            rows[row].isMerge = commit.parents.count > 1
        }

        self.rows = rows
        self.laneWidth = graph.width
    }
}
