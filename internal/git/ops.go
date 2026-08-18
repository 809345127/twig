package git

import (
	"fmt"
	"strings"
)

// —— 暂存区 ——

// Stage 把文件加入暂存区。paths 为空表示全部。
func (r *Repo) Stage(paths []string) (string, error) {
	args := []string{"add", "--"}
	if len(paths) == 0 {
		args = []string{"add", "-A", "--"}
	} else {
		args = append(args, paths...)
	}
	return r.RunUser(args...)
}

// Unstage 把文件移出暂存区。paths 为空表示全部。
func (r *Repo) Unstage(paths []string) (string, error) {
	args := []string{"restore", "--staged", "--"}
	if len(paths) == 0 {
		args = append(args, ".")
	} else {
		args = append(args, paths...)
	}
	out, err := r.RunUser(args...)
	if err == nil {
		return out, nil
	}
	// 空仓库还没有 HEAD，restore --staged 会失败，退回用 rm --cached。
	fallback := []string{"rm", "--cached", "-r", "--"}
	if len(paths) == 0 {
		fallback = append(fallback, ".")
	} else {
		fallback = append(fallback, paths...)
	}
	return r.RunUser(fallback...)
}

// Discard 丢弃工作区改动。untracked 的文件走删除，已跟踪的文件恢复成暂存区版本。
func (r *Repo) Discard(paths []string, untracked []string) (string, error) {
	var log []string
	if len(paths) > 0 {
		args := append([]string{"checkout", "--"}, paths...)
		out, err := r.RunUser(args...)
		log = append(log, out)
		if err != nil {
			return strings.Join(log, "\n"), err
		}
	}
	if len(untracked) > 0 {
		args := append([]string{"clean", "-fd", "--"}, untracked...)
		out, err := r.RunUser(args...)
		log = append(log, out)
		if err != nil {
			return strings.Join(log, "\n"), err
		}
	}
	return strings.Join(log, "\n"), nil
}

// —— 提交 ——

// CommitOptions 是一次提交的参数。
type CommitOptions struct {
	Message string
	Amend   bool
	// StageAll 表示提交前先把所有已跟踪文件的改动加进暂存区（相当于 commit -a）。
	StageAll bool
}

// Commit 创建一个提交。
func (r *Repo) Commit(opt CommitOptions) (string, error) {
	if strings.TrimSpace(opt.Message) == "" && !opt.Amend {
		return "", fmt.Errorf("commit message is empty")
	}
	args := []string{"commit"}
	if opt.StageAll {
		args = append(args, "-a")
	}
	if opt.Amend {
		args = append(args, "--amend")
	}
	if strings.TrimSpace(opt.Message) != "" {
		args = append(args, "-m", opt.Message)
	} else {
		args = append(args, "--no-edit")
	}
	return r.RunUser(args...)
}

// —— 分支 ——

// Checkout 切换到某个分支或提交。
func (r *Repo) Checkout(target string) (string, error) {
	return r.RunUser("checkout", target)
}

// CheckoutRemote 基于远程分支创建同名本地分支并切过去。
func (r *Repo) CheckoutRemote(remoteBranch string) (string, error) {
	local := remoteBranch
	if i := strings.Index(remoteBranch, "/"); i >= 0 {
		local = remoteBranch[i+1:]
	}
	// 本地已经有同名分支时直接切过去，避免报"已存在"。
	if _, err := r.run("rev-parse", "--verify", "-q", "refs/heads/"+local); err == nil {
		return r.RunUser("checkout", local)
	}
	return r.RunUser("checkout", "-b", local, "--track", remoteBranch)
}

// CreateBranch 创建分支；checkout 为 true 时顺便切过去。
func (r *Repo) CreateBranch(name, startPoint string, checkout bool) (string, error) {
	if strings.TrimSpace(name) == "" {
		return "", fmt.Errorf("branch name is empty")
	}
	if startPoint == "" {
		startPoint = "HEAD"
	}
	if checkout {
		return r.RunUser("checkout", "-b", name, startPoint)
	}
	return r.RunUser("branch", name, startPoint)
}

// DeleteBranch 删除本地分支。force 为 true 时用 -D（允许删除未合并的分支）。
func (r *Repo) DeleteBranch(name string, force bool) (string, error) {
	flag := "-d"
	if force {
		flag = "-D"
	}
	return r.RunUser("branch", flag, name)
}

// DeleteRemoteBranch 删除远程分支，name 形如 origin/feature-x。
func (r *Repo) DeleteRemoteBranch(name string) (string, error) {
	i := strings.Index(name, "/")
	if i < 0 {
		return "", fmt.Errorf("malformed remote branch name: %s", name)
	}
	return r.RunUser("push", name[:i], "--delete", name[i+1:])
}

// Merge 把 target 合并进当前分支。
func (r *Repo) Merge(target string, noFF bool) (string, error) {
	args := []string{"merge"}
	if noFF {
		args = append(args, "--no-ff")
	}
	args = append(args, target)
	return r.RunUser(args...)
}

// Rebase 把当前分支变基到 target 上。
func (r *Repo) Rebase(target string) (string, error) {
	return r.RunUser("rebase", target)
}

// Reset 把当前分支重置到某个提交。mode 取 soft / mixed / hard。
func (r *Repo) Reset(target, mode string) (string, error) {
	switch mode {
	case "soft", "mixed", "hard":
	default:
		return "", fmt.Errorf("unsupported reset mode: %s", mode)
	}
	return r.RunUser("reset", "--"+mode, target)
}

// —— 远端 ——

// Remotes 列出所有远端名。
func (r *Repo) Remotes() ([]string, error) {
	out, err := r.run("remote")
	if err != nil {
		return nil, err
	}
	var list []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			list = append(list, l)
		}
	}
	return list, nil
}

// Fetch 从远端拉取（含 --prune 清理已删除的远程分支）。remote 为空表示所有远端。
func (r *Repo) Fetch(remote string) (string, error) {
	args := []string{"fetch", "--prune", "--tags"}
	if remote == "" {
		args = append(args, "--all")
	} else {
		args = append(args, remote)
	}
	return r.RunUser(args...)
}

// Pull 拉取并合并当前分支的上游。
func (r *Repo) Pull(rebase bool) (string, error) {
	args := []string{"pull"}
	if rebase {
		args = append(args, "--rebase")
	}
	return r.RunUser(args...)
}

// Push 推送当前分支。首次推送时自动带上 -u 建立上游关联。
func (r *Repo) Push(force bool) (string, error) {
	head, err := r.Head()
	if err != nil {
		return "", err
	}
	if head.Detached || head.Branch == "" {
		return "", fmt.Errorf("detached HEAD — check out a branch first")
	}

	args := []string{"push"}
	if force {
		// 用 --force-with-lease 而不是 --force：远端有别人的新提交时会拒绝，不会误覆盖。
		args = append(args, "--force-with-lease")
	}

	// 没有上游时补 -u origin <branch>。
	if _, err := r.run("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"); err != nil {
		remotes, _ := r.Remotes()
		if len(remotes) == 0 {
			return "", fmt.Errorf("this repository has no remote configured")
		}
		remote := remotes[0]
		for _, rm := range remotes {
			if rm == "origin" {
				remote = "origin"
			}
		}
		args = append(args, "-u", remote, head.Branch)
	}
	return r.RunUser(args...)
}

// —— stash ——

// Stash 是一条 stash 记录。
type Stash struct {
	Ref     string `json:"ref"` // 形如 stash@{0}
	Subject string `json:"subject"`
	Time    int64  `json:"time"`
}

// StashList 列出所有 stash。
func (r *Repo) StashList() ([]Stash, error) {
	out, err := r.run("stash", "list", "--pretty=format:%gd"+fieldSep+"%gs"+fieldSep+"%at")
	if err != nil {
		return nil, err
	}
	list := []Stash{}
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Split(line, fieldSep)
		if len(f) < 3 {
			continue
		}
		var ts int64
		fmt.Sscanf(f[2], "%d", &ts)
		list = append(list, Stash{Ref: f[0], Subject: f[1], Time: ts})
	}
	return list, nil
}

// StashPush 把当前改动存进 stash。
func (r *Repo) StashPush(message string, includeUntracked bool) (string, error) {
	args := []string{"stash", "push"}
	if includeUntracked {
		args = append(args, "--include-untracked")
	}
	if strings.TrimSpace(message) != "" {
		args = append(args, "-m", message)
	}
	return r.RunUser(args...)
}

// StashApply 应用一条 stash；drop 为 true 时应用后删除（相当于 pop）。
func (r *Repo) StashApply(ref string, drop bool) (string, error) {
	verb := "apply"
	if drop {
		verb = "pop"
	}
	return r.RunUser("stash", verb, ref)
}

// StashDrop 删除一条 stash。
func (r *Repo) StashDrop(ref string) (string, error) {
	return r.RunUser("stash", "drop", ref)
}

// —— 中途状态 ——

// AbortState 中止进行中的 merge / rebase / cherry-pick / revert。
func (r *Repo) AbortState(state string) (string, error) {
	switch state {
	case "merge":
		return r.RunUser("merge", "--abort")
	case "rebase":
		return r.RunUser("rebase", "--abort")
	case "cherry-pick":
		return r.RunUser("cherry-pick", "--abort")
	case "revert":
		return r.RunUser("revert", "--abort")
	}
	return "", fmt.Errorf("nothing in progress to abort")
}

// ContinueState 继续进行中的 rebase / cherry-pick / revert。
func (r *Repo) ContinueState(state string) (string, error) {
	switch state {
	case "rebase":
		return r.RunUser("rebase", "--continue")
	case "cherry-pick":
		return r.RunUser("cherry-pick", "--continue")
	case "revert":
		return r.RunUser("revert", "--continue")
	}
	return "", fmt.Errorf("nothing in progress to continue")
}
