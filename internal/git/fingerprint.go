package git

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Fingerprint 给仓库当前状态算一个短指纹：指纹没变，界面上就没有需要更新的东西。
//
// 自动刷新靠它——每隔一两秒算一次，变了才让浏览器去重新拉数据。所以它必须**便宜**，
// 也必须**全**：漏掉一类变化，那类变化就永远不会自动刷新出来。
//
// 覆盖两类东西，缺一不可：
//
//  1. git status --porcelain=v2 --branch —— 一次调用就拿到 HEAD、当前分支、相对上游的
//     领先落后、暂存区、工作区改动、未跟踪文件。用户在编辑器里改一个文件，只有它能看见
//     （改工作区文件时 .git 底下一个字节都不会动，实测过）。
//
//  2. 引用文件的名字 + mtime + 大小 —— fetch 回来的远程分支、在别处建的/删的分支、
//     stash 的增减，git status 全看不见，但它们都会改变提交图。走文件系统比再调一次
//     git 便宜得多（colt 有 77 个 loose ref，遍历一次一毫秒都不到）。
//
// ⚠️ 指纹里**不要**放 .git/index 的 mtime 之外的自造字段，也不要在这里跑会写 .git 的
// 命令。轮询要是自己改动了被观测的东西，就会自己触发自己、永远刷不停。
// 我们跑的 git status 带着 GIT_OPTIONAL_LOCKS=0（见 exec.go），不会回写 index，实测确认过。
func (r *Repo) Fingerprint() (string, error) {
	h := sha256.New()

	out, err := r.runBytes("status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all")
	if err != nil {
		return "", err
	}
	h.Write(out)

	gitDir, err := r.resolveGitDir()
	if err != nil {
		// 拿不到 .git 也不算致命：至少工作区那部分还是准的，退化成"只看 status"。
		return hex.EncodeToString(h.Sum(nil))[:16], nil
	}

	// .git 顶层那些单文件：HEAD（切分支）、index（暂存）、packed-refs（fetch 后打包的引用）、
	// MERGE_HEAD / ORIG_HEAD / FETCH_HEAD（合并、变基、拉取进行中的状态）等等。
	// 只看这一层、不递归，避免 .git/objects 那种成千上万个文件的目录。
	if ents, err := os.ReadDir(gitDir); err == nil {
		for _, e := range ents {
			if e.IsDir() {
				continue
			}
			writeEntry(h, e.Name(), e)
		}
	}

	// refs/ 要递归，但它一般只有几十到几百个文件。
	refs := filepath.Join(gitDir, "refs")
	_ = filepath.WalkDir(refs, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil //nolint:nilerr // 读不到就跳过，指纹算少一点也比整个失败强
		}
		rel, _ := filepath.Rel(refs, p)
		writeEntry(h, rel, d)
		return nil
	})

	return hex.EncodeToString(h.Sum(nil))[:16], nil
}

// writeEntry 把一个文件的"身份 + 有没有变过"写进指纹。
func writeEntry(h interface{ Write([]byte) (int, error) }, name string, d fs.DirEntry) {
	info, err := d.Info()
	if err != nil {
		fmt.Fprintf(h, "%s\x00?\x00", name)
		return
	}
	fmt.Fprintf(h, "%s\x00%d\x00%d\x00", name, info.ModTime().UnixNano(), info.Size())
}

// resolveGitDir 找出真正的 .git 目录。
//
// 大多数时候就是 <仓库>/.git，但**在 worktree 和 submodule 里 .git 是个文件**，
// 内容形如 "gitdir: /path/to/real"，得跟过去。不处理的话这两种仓库会完全监听不到
// 分支变化——而且是静默的，看不出哪里错了。
func (r *Repo) resolveGitDir() (string, error) {
	p := filepath.Join(r.Dir, ".git")
	fi, err := os.Stat(p)
	if err != nil {
		return "", err
	}
	if fi.IsDir() {
		return p, nil
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", err
	}
	line := strings.TrimSpace(string(b))
	rest, ok := strings.CutPrefix(line, "gitdir:")
	if !ok {
		return "", fmt.Errorf("unexpected .git file contents in %s", r.Dir)
	}
	real := strings.TrimSpace(rest)
	if !filepath.IsAbs(real) {
		real = filepath.Join(r.Dir, real)
	}
	return real, nil
}
