package git

// 提交图的布局计算。
//
// 目标是把一串按时间排好序的提交，摆到若干条竖直的"轨道"（lane）上，
// 并算出提交之间的连线该走哪条轨道 —— 也就是 SourceTree 左边那张分叉合并图。
//
// 算法本身很朴素，一次从上往下扫：
//   - 维护一个 lanes 数组，lanes[i] 记录"第 i 条轨道正在等哪个提交出现"。
//   - 扫到一个提交时，先看有没有轨道在等它；有就站到那条轨道上，没有就占一条空轨道。
//   - 然后把它的父提交登记到轨道上：第一个父提交继续占用自己这条轨道（主干直着往下），
//     其余父提交（合并进来的那些）另开轨道。
//   - 多条轨道同时等同一个提交时，它们在这一行汇合，多余的轨道就地释放。

// Edge 是图上的一条连线：从 commit 连到它的某个父 commit。
type Edge struct {
	FromRow  int `json:"fromRow"`
	FromLane int `json:"fromLane"`
	ToRow    int `json:"toRow"`
	ToLane   int `json:"toLane"`
	// Lane 是这条线在中间路段占用的轨道。
	// 线的形状是：起点 → 拐到 Lane → 沿 Lane 一路向下 → 拐进终点。
	Lane int `json:"lane"`
	// Color 是配色索引，同一条分支链上的线颜色一致。
	Color int `json:"color"`
	// Merge 标记这是"合并线"（指向第二个及以后的父提交），前端可以画得细一点。
	Merge bool `json:"merge"`
}

// Graph 是布局结果。
type Graph struct {
	Commits []*Commit `json:"commits"`
	Edges   []Edge    `json:"edges"`
	// Width 是用到的轨道总数，前端据此决定图区宽度。
	Width int `json:"width"`
}

// Layout 计算提交图布局。commits 必须已按拓扑/时间序排好（父提交排在子提交之后）。
//
// 它会就地填充每个 commit 的 Row 与 Lane 字段。
func Layout(commits []*Commit) *Graph {
	g := &Graph{Commits: commits, Edges: []Edge{}}
	if len(commits) == 0 {
		return g
	}

	rowOf := make(map[string]int, len(commits))
	for i, c := range commits {
		rowOf[c.Hash] = i
	}

	// lanes[i] == "" 表示该轨道空闲，否则是它正在等待的 commit hash。
	lanes := []string{}
	// colorOf 让同一条分支链上的线保持同一个颜色。
	colorOf := make(map[string]int, len(commits))
	nextColor := 0

	// 边的终点要等扫到父提交那一行才知道落在哪条轨道，先把终点 hash 记下来。
	type pending struct {
		edgeIdx  int
		toCommit string
	}
	var pendings []pending

	allocLane := func() int {
		for i, t := range lanes {
			if t == "" {
				return i
			}
		}
		lanes = append(lanes, "")
		return len(lanes) - 1
	}
	findLane := func(hash string) int {
		for i, t := range lanes {
			if t == hash {
				return i
			}
		}
		return -1
	}

	maxLane := 0
	for row, c := range commits {
		myLane := findLane(c.Hash)
		if myLane < 0 {
			myLane = allocLane()
		}
		c.Row = row
		c.Lane = myLane
		if myLane > maxLane {
			maxLane = myLane
		}

		// 多条轨道同时在等这个提交：它们在这一行汇合，除自己外全部释放。
		for i := range lanes {
			if i != myLane && lanes[i] == c.Hash {
				lanes[i] = ""
			}
		}

		myColor, ok := colorOf[c.Hash]
		if !ok {
			myColor = nextColor
			nextColor++
			colorOf[c.Hash] = myColor
		}

		// 只连结果集里存在的父提交。被 limit 截断、或不在所选分支上的父提交直接丢弃，
		// 表现为线在这一行断掉 —— 这是符合预期的：用户只想看选中的那几条分支。
		var parents []string
		for _, p := range c.Parents {
			if _, ok := rowOf[p]; ok {
				parents = append(parents, p)
			}
		}

		if len(parents) == 0 {
			lanes[myLane] = ""
			continue
		}

		for i, p := range parents {
			reuse := findLane(p)
			var edgeLane, edgeColor int

			if i == 0 {
				// 第一个父提交：主干，尽量沿着自己这条轨道直着往下走。
				if reuse >= 0 && reuse != myLane {
					// 已经有轨道在等这个父提交了，汇进去，自己这条让出来。
					edgeLane = reuse
					lanes[myLane] = ""
				} else {
					lanes[myLane] = p
					edgeLane = myLane
				}
				edgeColor = myColor
				if _, ok := colorOf[p]; !ok {
					colorOf[p] = myColor // 主干颜色向下传递
				}
			} else {
				// 合并进来的父提交：另开一条轨道（或汇入已存在的那条）。
				if reuse >= 0 {
					edgeLane = reuse
				} else {
					edgeLane = allocLane()
					lanes[edgeLane] = p
				}
				if col, ok := colorOf[p]; ok {
					edgeColor = col
				} else {
					edgeColor = nextColor
					nextColor++
					colorOf[p] = edgeColor
				}
			}

			if edgeLane > maxLane {
				maxLane = edgeLane
			}
			g.Edges = append(g.Edges, Edge{
				FromRow:  row,
				FromLane: myLane,
				Lane:     edgeLane,
				Color:    edgeColor,
				Merge:    i > 0,
			})
			pendings = append(pendings, pending{edgeIdx: len(g.Edges) - 1, toCommit: p})
		}
	}

	// 回填每条边的终点。
	for _, pd := range pendings {
		toRow := rowOf[pd.toCommit]
		g.Edges[pd.edgeIdx].ToRow = toRow
		g.Edges[pd.edgeIdx].ToLane = commits[toRow].Lane
	}

	g.Width = maxLane + 1
	return g
}
