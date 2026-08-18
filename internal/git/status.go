package git

import "strings"

// FileChange 是工作区里的一个文件改动。
type FileChange struct {
	Path string `json:"path"`
	// OrigPath 仅在重命名 / 拷贝时有值，表示改名前的路径。
	OrigPath string `json:"origPath,omitempty"`
	// Index 是暂存区状态字符（git status 的 X 位），空格表示无改动。
	Index string `json:"index"`
	// Work 是工作区状态字符（git status 的 Y 位）。
	Work string `json:"work"`
	// Staged / Unstaged 是给界面用的两个布尔量，省得前端再解析状态字符。
	Staged    bool `json:"staged"`
	Unstaged  bool `json:"unstaged"`
	Untracked bool `json:"untracked"`
	Conflict  bool `json:"conflict"`
}

// Status 是工作区整体状态。
type Status struct {
	Staged   []FileChange `json:"staged"`
	Unstaged []FileChange `json:"unstaged"`
	// Conflicts 是有冲突的文件，单独列出来提醒。
	Conflicts []FileChange `json:"conflicts"`
	// Clean 表示工作区干净（无任何改动）。
	Clean bool `json:"clean"`
	// State 是仓库当前所处的特殊状态："" / "merge" / "rebase" / "cherry-pick" / "revert"
	State string `json:"state"`
}

// Status 读取工作区状态。
func (r *Repo) Status() (*Status, error) {
	out, err := r.runBytes("status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, err
	}

	st := &Status{Staged: []FileChange{}, Unstaged: []FileChange{}, Conflicts: []FileChange{}}

	// -z 格式：每条记录形如 "XY <path>\0"；重命名多跟一条 "<origPath>\0"。
	entries := strings.Split(string(out), "\x00")
	for i := 0; i < len(entries); i++ {
		e := entries[i]
		if len(e) < 4 {
			continue
		}
		x, y := string(e[0]), string(e[1])
		path := e[3:]

		fc := FileChange{Path: path, Index: x, Work: y}

		if x == "R" || x == "C" {
			// 重命名 / 拷贝的原路径在下一条记录里。
			if i+1 < len(entries) {
				fc.OrigPath = entries[i+1]
				i++
			}
		}

		switch {
		case x == "?" && y == "?":
			fc.Untracked = true
			fc.Unstaged = true
			st.Unstaged = append(st.Unstaged, fc)
		case isConflict(x, y):
			fc.Conflict = true
			st.Conflicts = append(st.Conflicts, fc)
		default:
			if x != " " && x != "?" {
				fc.Staged = true
				st.Staged = append(st.Staged, fc)
			}
			if y != " " && y != "?" {
				u := fc
				u.Staged = false
				u.Unstaged = true
				st.Unstaged = append(st.Unstaged, u)
			}
		}
	}

	st.Clean = len(st.Staged) == 0 && len(st.Unstaged) == 0 && len(st.Conflicts) == 0
	st.State = r.repoState()
	return st, nil
}

// isConflict 判断这对状态字符是否代表未解决的冲突。
func isConflict(x, y string) bool {
	switch x + y {
	case "DD", "AU", "UD", "UA", "DU", "AA", "UU":
		return true
	}
	return false
}

// repoState 判断仓库是否卡在 merge / rebase / cherry-pick / revert 中途。
func (r *Repo) repoState() string {
	gitDir, err := r.run("rev-parse", "--git-dir")
	if err != nil {
		return ""
	}
	dir := strings.TrimSpace(gitDir)
	if dir == "" {
		return ""
	}
	// 用 git 自己解析路径，避免 gitDir 是相对路径时拼错。
	exists := func(name string) bool {
		_, err := r.run("rev-parse", "--verify", "-q", name)
		return err == nil
	}
	switch {
	case exists("MERGE_HEAD"):
		return "merge"
	case exists("CHERRY_PICK_HEAD"):
		return "cherry-pick"
	case exists("REVERT_HEAD"):
		return "revert"
	case exists("REBASE_HEAD"):
		return "rebase"
	}
	return ""
}
