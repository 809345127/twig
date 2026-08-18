package git

import (
	"sort"
	"strconv"
	"strings"
)

// Commit 是提交历史里的一行。
type Commit struct {
	Hash       string   `json:"hash"`
	Short      string   `json:"short"`
	Parents    []string `json:"parents"`
	AuthorName string   `json:"authorName"`
	AuthorMail string   `json:"authorMail"`
	Timestamp  int64    `json:"timestamp"` // author date, unix 秒
	Subject    string   `json:"subject"`

	// 以下字段由 graph 布局阶段填充。
	Row  int `json:"row"`
	Lane int `json:"lane"`

	// Refs 是指向这个 commit 的分支 / tag 标签，由 Refs() 结果回填。
	Refs []Ref `json:"refs"`
}

// ensureRefs 保证 Refs 是空数组而不是 nil，方便前端直接遍历。
func (c *Commit) ensureRefs() {
	if c.Refs == nil {
		c.Refs = []Ref{}
	}
}

// Ref 是一个引用（本地分支、远程分支或 tag）。
type Ref struct {
	// Kind: "head"（本地分支） / "remote"（远程分支） / "tag"
	Kind string `json:"kind"`
	// Name 是简短名，如 main / origin/main / v1.2.0
	Name string `json:"name"`
	// FullName 是完整 refname，如 refs/heads/main
	FullName string `json:"fullName"`
	// Hash 是这个 ref 最终指向的 commit
	Hash string `json:"hash"`
	// Upstream 是本地分支的上游（如 origin/main），仅 Kind=="head" 时有意义
	Upstream string `json:"upstream"`
	// Ahead / Behind 是相对上游的领先 / 落后提交数
	Ahead  int `json:"ahead"`
	Behind int `json:"behind"`
	// IsHead 表示当前 HEAD 就检出在这个分支上
	IsHead bool `json:"isHead"`
}

const (
	fieldSep  = "\x1f"
	recordSep = "\x1e"
)

// LogOptions 控制读哪些提交。
type LogOptions struct {
	// Refs 是要画的分支 / tag。为空表示全部（--all）。
	Refs []string
	// Limit 是最多返回多少条提交。
	Limit int
	// FirstParent 为 true 时只沿第一父提交走，合并进来的分支细节会被折叠掉，
	// 图上只剩一条主线。看"这条分支上依次发生了什么"时很好用。
	FirstParent bool
}

// Log 读取提交历史。
//
// Refs 为空时按 --all 读取；否则只读这些 ref 可达的提交——
// 这正是"graph 只画我选的分支"的实现基础：交给 git 自己算可达性。
func (r *Repo) Log(opt LogOptions) ([]*Commit, error) {
	limit := opt.Limit
	if limit <= 0 {
		limit = 500
	}
	format := strings.Join([]string{"%H", "%P", "%an", "%ae", "%at", "%s"}, fieldSep) + recordSep

	args := []string{
		"log",
		"--date-order",
		"--pretty=format:" + format,
		"-n", strconv.Itoa(limit),
	}
	if opt.FirstParent {
		args = append(args, "--first-parent")
	}
	if len(opt.Refs) == 0 {
		args = append(args, "--all")
	} else {
		args = append(args, opt.Refs...)
	}
	// 用 -- 收尾，避免分支名和文件名歧义。
	args = append(args, "--")

	out, err := r.run(args...)
	if err != nil {
		return nil, err
	}

	var commits []*Commit
	for _, rec := range strings.Split(out, recordSep) {
		rec = strings.TrimLeft(rec, "\n")
		if strings.TrimSpace(rec) == "" {
			continue
		}
		f := strings.Split(rec, fieldSep)
		if len(f) < 6 {
			continue
		}
		ts, _ := strconv.ParseInt(f[4], 10, 64)
		// 根提交没有父提交，这里也保持成空数组而不是 nil，
		// 免得 JSON 里变成 null 让前端多一层判空。
		parents := []string{}
		if p := strings.TrimSpace(f[1]); p != "" {
			parents = strings.Fields(p)
		}
		short := f[0]
		if len(short) > 8 {
			short = short[:8]
		}
		commits = append(commits, &Commit{
			Hash:       f[0],
			Short:      short,
			Parents:    parents,
			AuthorName: f[2],
			AuthorMail: f[3],
			Timestamp:  ts,
			Subject:    f[5],
		})
	}
	return commits, nil
}

// Refs 列出所有本地分支、远程分支和 tag。
func (r *Repo) Refs() ([]Ref, error) {
	const f = "%(refname)" + fieldSep +
		"%(refname:short)" + fieldSep +
		"%(objectname)" + fieldSep +
		"%(*objectname)" + fieldSep +
		"%(upstream:short)" + fieldSep +
		"%(upstream:track)" + fieldSep +
		"%(HEAD)"

	out, err := r.run("for-each-ref", "--format="+f, "refs/heads", "refs/remotes", "refs/tags")
	if err != nil {
		return nil, err
	}

	var refs []Ref
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		p := strings.Split(line, fieldSep)
		if len(p) < 7 {
			continue
		}
		full, short, obj, peeled, upstream, track, head := p[0], p[1], p[2], p[3], p[4], p[5], p[6]

		hash := obj
		if peeled != "" {
			// 带注释的 tag：%(objectname) 是 tag 对象自身，要取它指向的 commit。
			hash = peeled
		}

		kind := "head"
		switch {
		case strings.HasPrefix(full, "refs/remotes/"):
			kind = "remote"
		case strings.HasPrefix(full, "refs/tags/"):
			kind = "tag"
		}
		// origin/HEAD 只是个符号链接，画在图上没有意义。
		if kind == "remote" && strings.HasSuffix(short, "/HEAD") {
			continue
		}

		ahead, behind := parseTrack(track)
		refs = append(refs, Ref{
			Kind:     kind,
			Name:     short,
			FullName: full,
			Hash:     hash,
			Upstream: upstream,
			Ahead:    ahead,
			Behind:   behind,
			IsHead:   head == "*",
		})
	}

	// 排序：本地分支 → 远程分支 → tag，各自按名字。
	order := map[string]int{"head": 0, "remote": 1, "tag": 2}
	sort.SliceStable(refs, func(i, j int) bool {
		if order[refs[i].Kind] != order[refs[j].Kind] {
			return order[refs[i].Kind] < order[refs[j].Kind]
		}
		return refs[i].Name < refs[j].Name
	})
	return refs, nil
}

// parseTrack 解析 %(upstream:track) 形如 "[ahead 2, behind 1]" 的字符串。
func parseTrack(track string) (ahead, behind int) {
	track = strings.Trim(track, "[]")
	for _, part := range strings.Split(track, ",") {
		part = strings.TrimSpace(part)
		switch {
		case strings.HasPrefix(part, "ahead "):
			ahead, _ = strconv.Atoi(strings.TrimPrefix(part, "ahead "))
		case strings.HasPrefix(part, "behind "):
			behind, _ = strconv.Atoi(strings.TrimPrefix(part, "behind "))
		}
	}
	return
}

// HeadInfo 描述 HEAD 当前的位置。
type HeadInfo struct {
	// Branch 是当前分支名；detached HEAD 时为空。
	Branch   string `json:"branch"`
	Hash     string `json:"hash"`
	Detached bool   `json:"detached"`
}

// Head 读取 HEAD 状态。
func (r *Repo) Head() (HeadInfo, error) {
	var h HeadInfo
	if out, err := r.run("symbolic-ref", "-q", "--short", "HEAD"); err == nil {
		h.Branch = strings.TrimSpace(out)
	} else {
		h.Detached = true
	}
	out, err := r.run("rev-parse", "HEAD")
	if err != nil {
		// 空仓库（还没有任何提交）：不算错误。
		return h, nil
	}
	h.Hash = strings.TrimSpace(out)
	return h, nil
}

// AttachRefs 把 refs 挂到对应的 commit 上。
func AttachRefs(commits []*Commit, refs []Ref) {
	byHash := make(map[string]*Commit, len(commits))
	for _, c := range commits {
		byHash[c.Hash] = c
	}
	for _, ref := range refs {
		if c, ok := byHash[ref.Hash]; ok {
			c.Refs = append(c.Refs, ref)
		}
	}
	for _, c := range commits {
		c.ensureRefs()
	}
}
