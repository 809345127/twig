package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// AppState 是跨会话保存的界面偏好，落在 ~/.twig/state.json。
type AppState struct {
	// Recent 是最近打开过的仓库路径，最新的排在最前。
	Recent []string `json:"recent"`
	// SelectedRefs 记录每个仓库上次在图上勾选了哪几个分支。
	// key 是仓库路径，value 是 ref 全名列表；空列表表示"全部"。
	SelectedRefs map[string][]string `json:"selectedRefs"`

	mu   sync.Mutex
	path string
}

const maxRecent = 15

// loadState 读取磁盘上的偏好；文件不存在或损坏时返回一份空的。
func loadState() *AppState {
	st := &AppState{SelectedRefs: map[string][]string{}}

	home, err := os.UserHomeDir()
	if err != nil {
		return st
	}
	dir := filepath.Join(home, ".twig")
	st.path = filepath.Join(dir, "state.json")

	b, err := os.ReadFile(st.path)
	if err != nil {
		return st
	}
	var disk AppState
	if err := json.Unmarshal(b, &disk); err != nil {
		return st
	}
	st.Recent = disk.Recent
	if disk.SelectedRefs != nil {
		st.SelectedRefs = disk.SelectedRefs
	}
	return st
}

// save 把偏好写回磁盘。写失败不影响使用，静默忽略。
func (s *AppState) save() {
	if s.path == "" {
		return
	}
	_ = os.MkdirAll(filepath.Dir(s.path), 0o755)

	type diskState struct {
		Recent       []string            `json:"recent"`
		SelectedRefs map[string][]string `json:"selectedRefs"`
	}
	b, err := json.MarshalIndent(diskState{Recent: s.Recent, SelectedRefs: s.SelectedRefs}, "", "  ")
	if err != nil {
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp, s.path)
}

// touchRecent 把某个仓库提到最近列表最前面。
func (s *AppState) touchRecent(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	list := []string{path}
	for _, p := range s.Recent {
		if p != path {
			list = append(list, p)
		}
	}
	if len(list) > maxRecent {
		list = list[:maxRecent]
	}
	s.Recent = list
	s.save()
}

// forgetRecent 从最近列表里移除一个仓库。
func (s *AppState) forgetRecent(path string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	var list []string
	for _, p := range s.Recent {
		if p != path {
			list = append(list, p)
		}
	}
	s.Recent = list
	delete(s.SelectedRefs, path)
	s.save()
}

// recentList 返回最近打开的仓库（只保留仍然存在的目录）。
func (s *AppState) recentList() []string {
	s.mu.Lock()
	defer s.mu.Unlock()

	list := []string{}
	changed := false
	for _, p := range s.Recent {
		if fi, err := os.Stat(p); err == nil && fi.IsDir() {
			list = append(list, p)
		} else {
			changed = true
		}
	}
	if changed {
		s.Recent = list
		s.save()
	}
	return list
}

// setSelectedRefs 记住某个仓库勾选的分支。
func (s *AppState) setSelectedRefs(repo string, refs []string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.SelectedRefs == nil {
		s.SelectedRefs = map[string][]string{}
	}
	if refs == nil {
		refs = []string{}
	}
	s.SelectedRefs[repo] = refs
	s.save()
}

// getSelectedRefs 取出某个仓库上次勾选的分支。
//
// ⚠️ 从没打开过的仓库要返回空切片，不能是 nil——Go 的 nil 切片序列化成 JSON 是
// null 不是 []，客户端（含 mac/ 那套 Swift 原生外壳）按非 optional 数组解码会直接
// 崩溃。这个仓库里其它同类地方（parseDiffStats、handleRefs、buildRepoInfo 的
// Remotes……）都已经这么处理了，这处是漏网的一个：实测用一个全新仓库（从没记录过
// 勾选状态的）连 /api/bootstrap，Swift 端在 selectedRefs 字段解码时直接报错退出。
func (s *AppState) getSelectedRefs(repo string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()

	if refs, ok := s.SelectedRefs[repo]; ok {
		return refs
	}
	return []string{}
}
