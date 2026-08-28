package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"twig/internal/git"
)

// repoInfo 是界面顶部展示的仓库概况。
type repoInfo struct {
	Path    string       `json:"path"`
	Name    string       `json:"name"`
	Head    git.HeadInfo `json:"head"`
	Remotes []string     `json:"remotes"`
	// SelectedRefs 是上次记住的分支勾选（空表示全部）。
	SelectedRefs []string `json:"selectedRefs"`
}

func (s *Server) buildRepoInfo(r *git.Repo) (*repoInfo, error) {
	head, err := r.Head()
	if err != nil {
		return nil, err
	}
	remotes, _ := r.Remotes()
	if remotes == nil {
		remotes = []string{}
	}
	return &repoInfo{
		Path:         r.Dir,
		Name:         filepath.Base(r.Dir),
		Head:         head,
		Remotes:      remotes,
		SelectedRefs: s.state.getSelectedRefs(r.Dir),
	}, nil
}

// GET /api/ping —— 探活。
//
// 另一个 twig 进程启动时用它确认"这个端口上跑着的确实是我们自己"，
// 而不是碰巧占了同一个端口的别的程序。
func (s *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"app": "twig", "pid": os.Getpid()})
}

// GET /api/bootstrap —— 页面加载时的第一份数据。
func (s *Server) handleBootstrap(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"recent": s.state.recentList(),
		"home":   userHome(),
		"repo":   nil,
	}
	s.mu.Lock()
	repo := s.repo
	s.mu.Unlock()
	if repo != nil {
		if info, err := s.buildRepoInfo(repo); err == nil {
			resp["repo"] = info
		}
	}
	writeJSON(w, resp)
}

// POST /api/open —— 打开一个仓库。
func (s *Server) handleOpen(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, err)
		return
	}
	if err := s.OpenRepo(req.Path); err != nil {
		writeErr(w, err)
		return
	}
	repo, _ := s.currentRepo()
	info, err := s.buildRepoInfo(repo)
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, info)
}

// OpenRepo 打开仓库并记入最近列表。启动参数与界面都走这里。
func (s *Server) OpenRepo(path string) error {
	path = expandHome(strings.TrimSpace(path))
	if path == "" {
		return fmt.Errorf("path is empty")
	}
	repo, err := git.Open(path)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.repo = repo
	s.mu.Unlock()
	s.state.touchRecent(repo.Dir)
	return nil
}

// OpenMostRecent 打开最近一次用过的仓库。
//
// 双击 App 图标启动时没有"当前目录"可用，这时回到上次看的那个仓库
// 比甩一个空界面给用户好。
func (s *Server) OpenMostRecent() error {
	for _, p := range s.state.recentList() {
		if err := s.OpenRepo(p); err == nil {
			return nil
		}
	}
	return fmt.Errorf("no usable repository in the recent list")
}

// POST /api/forget —— 从最近列表里移除。
func (s *Server) handleForget(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, err)
		return
	}
	s.state.forgetRecent(req.Path)
	writeJSON(w, map[string]any{"recent": s.state.recentList()})
}

// GET /api/browse —— 简易目录浏览，用来在界面上挑仓库。
func (s *Server) handleBrowse(w http.ResponseWriter, r *http.Request) {
	path := expandHome(r.URL.Query().Get("path"))
	if path == "" {
		path = userHome()
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		writeErr(w, err)
		return
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		writeErr(w, err)
		return
	}

	type item struct {
		Name  string `json:"name"`
		Path  string `json:"path"`
		IsGit bool   `json:"isGit"`
	}
	list := []item{}
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		p := filepath.Join(abs, e.Name())
		isGit := false
		if fi, err := os.Stat(filepath.Join(p, ".git")); err == nil {
			isGit = fi.IsDir() || fi.Mode().IsRegular()
		}
		list = append(list, item{Name: e.Name(), Path: p, IsGit: isGit})
	}
	sort.Slice(list, func(i, j int) bool { return strings.ToLower(list[i].Name) < strings.ToLower(list[j].Name) })

	parent := filepath.Dir(abs)
	if parent == abs {
		parent = ""
	}
	// 当前目录本身是不是仓库，界面上要能直接选它。
	selfIsGit := false
	if fi, err := os.Stat(filepath.Join(abs, ".git")); err == nil {
		selfIsGit = fi.IsDir() || fi.Mode().IsRegular()
	}

	writeJSON(w, map[string]any{
		"path":      abs,
		"parent":    parent,
		"entries":   list,
		"selfIsGit": selfIsGit,
	})
}

// GET /api/refs —— 分支 / tag 列表。
func (s *Server) handleRefs(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	refs, err := repo.Refs()
	if err != nil {
		writeErr(w, err)
		return
	}
	if refs == nil {
		refs = []git.Ref{}
	}
	head, _ := repo.Head()
	writeJSON(w, map[string]any{
		"refs":     refs,
		"head":     head,
		"selected": s.state.getSelectedRefs(repo.Dir),
	})
}

// GET /api/graph —— 提交图。
//
// refs 参数是逗号分隔的 ref 全名；为空表示画全部分支。
// 这就是 twig 相对 SourceTree 多出来的那件事：图上画哪几条分支由调用方指定。
func (s *Server) handleGraph(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	q := r.URL.Query()
	refs := splitRefs(q.Get("refs"))
	limit, _ := strconv.Atoi(q.Get("limit"))
	if limit <= 0 {
		limit = 500
	}
	firstParent := q.Get("firstParent") == "1"

	// 记住这次的勾选，下次打开同一个仓库直接恢复。
	if q.Get("remember") != "0" {
		s.state.setSelectedRefs(repo.Dir, refs)
	}

	commits, err := repo.Log(git.LogOptions{Refs: refs, Limit: limit, FirstParent: firstParent})
	if err != nil {
		writeErr(w, err)
		return
	}
	allRefs, err := repo.Refs()
	if err != nil {
		writeErr(w, err)
		return
	}
	git.AttachRefs(commits, allRefs)
	graph := git.Layout(commits)
	if graph.Commits == nil {
		graph.Commits = []*git.Commit{}
	}

	head, _ := repo.Head()
	writeJSON(w, map[string]any{
		"graph":    graph,
		"head":     head,
		"limit":    limit,
		"returned": len(graph.Commits),
	})
}

// diffOpts 从 query 里读出 diff 选项。四个出 diff 的接口都走它，口径才一致。
//
// ws=1 对应界面上的 "Ignore whitespace"。注意它开着的时候，只有空白改动的文件
// 会从 git 的输出里整个消失——文件清单里也就看不到它了，这是 git 的行为，不是漏了。
func diffOpts(r *http.Request) git.DiffOptions {
	return git.DiffOptions{IgnoreWhitespace: r.URL.Query().Get("ws") == "1"}
}

// GET /api/commit?hash=... —— 单个提交的详情与 diff。
func (s *Server) handleCommit(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	hash := r.URL.Query().Get("hash")
	if hash == "" {
		writeErr(w, fmt.Errorf("missing 'hash' parameter"))
		return
	}
	if err := checkArgs(hash); err != nil {
		writeErr(w, err)
		return
	}
	detail, err := repo.CommitDetail(hash, diffOpts(r))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, detail)
}

// GET /api/rangediff —— 比较两个提交版本之间的差异。
//
// 对应界面上按住 Cmd / Ctrl 勾中两个提交：from 是较旧的那个版本，to 是较新的。
func (s *Server) handleRangeDiff(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	q := r.URL.Query()
	from, to := q.Get("from"), q.Get("to")
	if from == "" || to == "" {
		writeErr(w, fmt.Errorf("missing 'from' or 'to' parameter"))
		return
	}
	if err := checkArgs(from, to); err != nil {
		writeErr(w, err)
		return
	}
	d, err := repo.RangeDiff(from, to, diffOpts(r))
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, d)
}

// GET /api/status —— 工作区状态。
func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	st, err := repo.Status()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, st)
}

// GET /api/patch —— 某一个文件的原始 patch 文本。
//
// 提交详情、比较两个版本、工作区三种视图共用这一个接口，靠 mode 区分：
//
//	mode=commit  hash=<提交>                      看某一个提交里的这个文件
//	mode=range   from=<旧版本> to=<新版本>          比较两个版本
//	mode=work    staged=0|1  untracked=0|1        工作区
//
// 三种都可以带 path / orig（重命名前的路径）/ ws（忽略空白）。
//
// 给的是 git 的原样输出，不是解析好的结构：前端交给 diff2html 渲染，
// 并排视图、行内高亮、语法着色都由它负责，我们不必也不该再翻译一遍。
func (s *Server) handlePatch(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	q := r.URL.Query()
	path, orig := q.Get("path"), q.Get("orig")
	if path == "" {
		writeErr(w, fmt.Errorf("missing 'path' parameter"))
		return
	}
	opt := diffOpts(r)

	var (
		patch     string
		truncated bool
	)
	switch mode := q.Get("mode"); mode {
	case "commit":
		hash := q.Get("hash")
		if hash == "" {
			writeErr(w, fmt.Errorf("missing 'hash' parameter"))
			return
		}
		// 只校验 ref：文件路径不能一起拦，命令里已经用 -- 隔开了，
		// 拦掉的话像 -weird.txt 这种合法文件名反而打不开。
		if err := checkArgs(hash); err != nil {
			writeErr(w, err)
			return
		}
		patch, truncated, err = repo.CommitFilePatch(hash, path, orig, opt)

	case "range":
		from, to := q.Get("from"), q.Get("to")
		if from == "" || to == "" {
			writeErr(w, fmt.Errorf("missing 'from' or 'to' parameter"))
			return
		}
		if err := checkArgs(from, to); err != nil {
			writeErr(w, err)
			return
		}
		patch, truncated, err = repo.RangeFilePatch(from, to, path, orig, opt)

	case "work":
		patch, truncated, err = repo.WorkFilePatch(path, q.Get("staged") == "1", q.Get("untracked") == "1", opt)

	default:
		writeErr(w, fmt.Errorf("unknown mode %q (want commit / range / work)", mode))
		return
	}
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"patch": patch, "truncated": truncated})
}

// GET /api/stashes —— stash 列表。
func (s *Server) handleStashes(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	list, err := repo.StashList()
	if err != nil {
		writeErr(w, err)
		return
	}
	writeJSON(w, map[string]any{"stashes": list})
}

// opRequest 是所有写操作的统一入参。
type opRequest struct {
	Action string `json:"action"`

	Paths     []string `json:"paths"`
	Untracked []string `json:"untracked"`

	Message  string `json:"message"`
	Amend    bool   `json:"amend"`
	StageAll bool   `json:"stageAll"`

	Target           string `json:"target"`
	Name             string `json:"name"`
	StartPoint       string `json:"startPoint"`
	Checkout         bool   `json:"checkout"`
	Force            bool   `json:"force"`
	NoFF             bool   `json:"noFF"`
	Rebase           bool   `json:"rebase"`
	Mode             string `json:"mode"`
	Remote           string `json:"remote"`
	Ref              string `json:"ref"`
	Drop             bool   `json:"drop"`
	State            string `json:"state"`
	IncludeUntracked bool   `json:"includeUntracked"`
}

// POST /api/op —— 所有会改动仓库的操作都走这一个入口。
func (s *Server) handleOp(w http.ResponseWriter, r *http.Request) {
	repo, err := s.currentRepo()
	if err != nil {
		writeErr(w, err)
		return
	}
	var req opRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, err)
		return
	}
	// 分支名 / 提交号这类参数会直接跟在子命令后面，没有 -- 保护，
	// 先挡掉能被 git 当成命令行选项的值。
	// （文件路径不用管：所有涉及路径的命令都加了 -- 分隔符。）
	if err := checkArgs(req.Target, req.Name, req.StartPoint, req.Remote, req.Ref); err != nil {
		writeErr(w, err)
		return
	}

	var out string
	switch req.Action {
	case "stage":
		out, err = repo.Stage(req.Paths)
	case "unstage":
		out, err = repo.Unstage(req.Paths)
	case "discard":
		out, err = repo.Discard(req.Paths, req.Untracked)
	case "commit":
		out, err = repo.Commit(git.CommitOptions{Message: req.Message, Amend: req.Amend, StageAll: req.StageAll})
	case "checkout":
		out, err = repo.Checkout(req.Target)
	case "checkoutRemote":
		out, err = repo.CheckoutRemote(req.Target)
	case "createBranch":
		out, err = repo.CreateBranch(req.Name, req.StartPoint, req.Checkout)
	case "deleteBranch":
		out, err = repo.DeleteBranch(req.Name, req.Force)
	case "deleteRemoteBranch":
		out, err = repo.DeleteRemoteBranch(req.Name)
	case "merge":
		out, err = repo.Merge(req.Target, req.NoFF)
	case "rebase":
		out, err = repo.Rebase(req.Target)
	case "reset":
		out, err = repo.Reset(req.Target, req.Mode)
	case "fetch":
		out, err = repo.Fetch(req.Remote)
	case "pull":
		out, err = repo.Pull(req.Rebase)
	case "push":
		out, err = repo.Push(req.Force)
	case "stashPush":
		out, err = repo.StashPush(req.Message, req.IncludeUntracked)
	case "stashApply":
		out, err = repo.StashApply(req.Ref, req.Drop)
	case "stashDrop":
		out, err = repo.StashDrop(req.Ref)
	case "abort":
		out, err = repo.AbortState(req.State)
	case "continue":
		out, err = repo.ContinueState(req.State)
	default:
		writeErr(w, fmt.Errorf("unknown action: %s", req.Action))
		return
	}

	if err != nil {
		// 失败时也把 git 的输出带回去，界面上能看到原始报错。
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error(), "output": out})
		return
	}
	writeJSON(w, map[string]any{"output": out})
}

// —— 路径工具 ——

func userHome() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return "/"
	}
	return h
}

// expandHome 把开头的 ~ 展开成家目录。
func expandHome(p string) string {
	if p == "~" {
		return userHome()
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(userHome(), p[2:])
	}
	return p
}
