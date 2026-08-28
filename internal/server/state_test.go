package server

import "testing"

// getSelectedRefs 对一个从没记录过的仓库，必须返回空切片而不是 nil——
// Go 的 nil 切片序列化成 JSON 是 null，客户端（含 mac/ 原生外壳）按非 optional
// 数组解码会直接崩溃。实测一个全新仓库触发过这个 bug，这里钉住不再回归。
func TestGetSelectedRefsNeverNil(t *testing.T) {
	st := &AppState{SelectedRefs: map[string][]string{}}
	got := st.getSelectedRefs("/never/opened/before")
	if got == nil {
		t.Fatal("从没记录过的仓库返回了 nil，序列化会变成 JSON null")
	}
	if len(got) != 0 {
		t.Errorf("期望空切片，得到 %v", got)
	}

	// 已经记录过的仓库仍然要原样返回。
	st.SelectedRefs["/some/repo"] = []string{"refs/heads/main"}
	got2 := st.getSelectedRefs("/some/repo")
	if len(got2) != 1 || got2[0] != "refs/heads/main" {
		t.Errorf("已记录的勾选没有原样返回：%v", got2)
	}
}
