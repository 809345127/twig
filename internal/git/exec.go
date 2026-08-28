// Package git 是对 git 命令行的一层薄封装。
//
// 这里不使用 libgit2 之类的绑定库：直接调用 git 可执行文件，行为和用户
// 在终端里敲的完全一致，也不会因为库版本落后而缺特性。
package git

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Repo 代表一个本地仓库工作区。
type Repo struct {
	// Dir 是仓库的工作区根目录（不是 .git 目录）。
	Dir string
}

// Open 校验 path 是否位于一个 git 仓库中，并返回该仓库的工作区根目录。
func Open(path string) (*Repo, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, err
	}
	if fi, err := os.Stat(abs); err != nil {
		return nil, fmt.Errorf("path does not exist: %s", abs)
	} else if !fi.IsDir() {
		abs = filepath.Dir(abs)
	}

	r := &Repo{Dir: abs}
	out, err := r.run("rev-parse", "--show-toplevel")
	if err != nil {
		return nil, fmt.Errorf("not a git repository: %s", abs)
	}
	top := strings.TrimSpace(out)
	if top == "" {
		return nil, fmt.Errorf("not a git repository: %s", abs)
	}
	return &Repo{Dir: top}, nil
}

// ErrGit 携带 git 命令失败时的退出码与 stderr，便于原样呈现给界面。
type ErrGit struct {
	Args   []string
	Stderr string
	Err    error
}

func (e *ErrGit) Error() string {
	msg := strings.TrimSpace(e.Stderr)
	if msg == "" {
		msg = e.Err.Error()
	}
	return msg
}

// run 执行一条 git 命令并返回 stdout（字符串）。
func (r *Repo) run(args ...string) (string, error) {
	b, err := r.runBytes(args...)
	return string(b), err
}

// gitPrefix 是每条 git 命令都要带上的全局参数。
//
// core.quotePath=false：git 默认会把路径里的非 ASCII 字符转义成 \344\270\255 这种八进制，
// 中文文件名在界面上就成了一串乱码、点开还找不到文件。关掉它让 git 直接输出 UTF-8。
// （只影响非 ASCII；含引号、制表符的路径 git 照样会加引号，那部分由 unquotePath 还原。）
var gitPrefix = []string{"-c", "core.quotePath=false"}

// runBytes 执行一条 git 命令并返回原始 stdout 字节。
//
// 需要原始字节是因为多处解析依赖 NUL 分隔（-z），且 diff 内容可能不是 UTF-8。
func (r *Repo) runBytes(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", append(append([]string{}, gitPrefix...), args...)...)
	cmd.Dir = r.Dir
	// 关掉交互式凭证弹窗与分页器，避免命令挂死等待输入。
	cmd.Env = append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_PAGER=cat",
		"GIT_OPTIONAL_LOCKS=0",
		"LC_ALL=C",
	)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, &ErrGit{Args: args, Stderr: "git command timed out (120s)", Err: err}
		}
		// 失败时也把已经产出的 stdout 一并返回：有些子命令（例如 diff --no-index）
		// 在"有差异"时就退出码非 0，输出本身是有效的。
		return stdout.Bytes(), &ErrGit{Args: args, Stderr: stderr.String(), Err: err}
	}
	return stdout.Bytes(), nil
}

// RunUser 执行一条会改变仓库状态的 git 命令，成功时把 stdout+stderr 一起返回。
//
// git 的许多写操作（push / pull / checkout）把进度信息写到 stderr，
// 界面上要一并展示，所以这里不像 run 那样丢弃 stderr。
func (r *Repo) RunUser(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "git", append(append([]string{}, gitPrefix...), args...)...)
	cmd.Dir = r.Dir
	cmd.Env = append(os.Environ(),
		"GIT_TERMINAL_PROMPT=0",
		"GIT_PAGER=cat",
		"LC_ALL=C",
	)

	var combined bytes.Buffer
	cmd.Stdout = &combined
	cmd.Stderr = &combined
	err := cmd.Run()
	if err != nil {
		return combined.String(), &ErrGit{Args: args, Stderr: combined.String(), Err: err}
	}
	return combined.String(), nil
}
