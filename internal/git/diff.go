package git

import (
	"errors"
	"strconv"
	"strings"
	"unicode/utf8"
)

// CommitDetail 是点开一个提交后看到的全部信息。
type CommitDetail struct {
	Commit
	Body       string     `json:"body"`
	CommitDate int64      `json:"commitDate"`
	Files      []DiffFile `json:"files"`
}

// DiffFile 是一个文件的改动，含逐行内容。
type DiffFile struct {
	Path     string `json:"path"`
	OrigPath string `json:"origPath,omitempty"`
	// Status: A 新增 / M 修改 / D 删除 / R 重命名 / C 拷贝
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	Binary    bool   `json:"binary"`
	Hunks     []Hunk `json:"hunks"`
	// Truncated 表示改动过大，只返回了前若干行。
	Truncated bool `json:"truncated"`
}

// Hunk 是一段连续的改动。
type Hunk struct {
	Header string     `json:"header"`
	Lines  []DiffLine `json:"lines"`
}

// DiffLine 是 diff 里的一行。
type DiffLine struct {
	// Kind: "ctx" 上下文 / "add" 新增 / "del" 删除
	Kind    string `json:"kind"`
	OldLine int    `json:"oldLine"` // 0 表示该行在旧文件里不存在
	NewLine int    `json:"newLine"`
	Text    string `json:"text"`
}

// maxDiffLinesPerFile 限制单文件返回的 diff 行数，避免超大文件把浏览器卡死。
const maxDiffLinesPerFile = 4000

// commitMeta 读取单个提交的元信息（作者 / 时间 / 标题 / 正文），不含 diff。
//
// 单独抽出来是因为"看一个提交"和"比较两个版本"都要用它。
func (r *Repo) commitMeta(hash string) (*CommitDetail, error) {
	format := strings.Join([]string{"%H", "%P", "%an", "%ae", "%at", "%ct", "%s", "%b"}, fieldSep)
	out, err := r.run("show", "-s", "--pretty=format:"+format, hash)
	if err != nil {
		return nil, err
	}
	f := strings.Split(out, fieldSep)
	if len(f) < 8 {
		return nil, &ErrGit{Stderr: "cannot parse commit info: " + hash}
	}
	ts, _ := strconv.ParseInt(f[4], 10, 64)
	cts, _ := strconv.ParseInt(f[5], 10, 64)
	short := f[0]
	if len(short) > 8 {
		short = short[:8]
	}
	d := &CommitDetail{
		Commit: Commit{
			Hash:       f[0],
			Short:      short,
			Parents:    strings.Fields(f[1]),
			AuthorName: f[2],
			AuthorMail: f[3],
			Timestamp:  ts,
			Subject:    f[6],
		},
		Body:       strings.TrimRight(f[7], "\n"),
		CommitDate: cts,
		Files:      []DiffFile{},
	}
	// 空切片会被序列化成 JSON null，前端拿它当数组用就会炸。
	// 这里的 refs 目前没人读，但下一个往上加代码的人多半会读。
	d.ensureRefs()
	return d, nil
}

// CommitDetail 读取单个提交的详情（含 diff）。
func (r *Repo) CommitDetail(hash string) (*CommitDetail, error) {
	d, err := r.commitMeta(hash)
	if err != nil {
		return nil, err
	}

	// 合并提交默认不产出 diff，用 -m 让它对第一个父提交出 diff。
	args := []string{"show", "--no-color", "-m", "--first-parent", "--patch",
		"--find-renames", "--format=", hash}
	patch, err := r.runBytes(args...)
	if err != nil {
		return nil, err
	}
	d.Files = parseUnifiedDiff(string(patch))
	return d, nil
}

// RangeDetail 是"比较两个提交版本"的结果，对应界面上按住 Cmd 勾中两个提交。
type RangeDetail struct {
	From *Commit `json:"from"`
	To   *Commit `json:"to"`
	// Files 是从 From 那个版本变成 To 那个版本，文件上发生的全部改动。
	Files []DiffFile `json:"files"`
	// Ahead 是 To 独有的提交数，Behind 是 From 独有的提交数。
	// Behind 为 0 说明 From 是 To 的祖先，两个版本在一条直线上；
	// 两个都不为 0 说明它们从某处分叉、各自走了一段。
	Ahead  int `json:"ahead"`
	Behind int `json:"behind"`
}

// RangeDiff 比较两个提交之间的差异，等价于 git diff <from> <to>。
//
// 这里用的是两点 diff，也就是直接比较两个版本的快照，而不是三点的
// from...to（那个只算 To 这一侧新增的改动、把 From 独有的部分忽略掉）。
// 界面上勾两个提交，想看的就是"这两个版本到底哪里不一样"，所以要两点。
func (r *Repo) RangeDiff(from, to string) (*RangeDetail, error) {
	fc, err := r.commitMeta(from)
	if err != nil {
		return nil, err
	}
	tc, err := r.commitMeta(to)
	if err != nil {
		return nil, err
	}
	d := &RangeDetail{From: &fc.Commit, To: &tc.Commit, Files: []DiffFile{}}

	// 一次拿到两侧各自独有的提交数，用来在界面上说清这是前后关系还是分叉。
	// 这一步只是补充信息，失败了不影响 diff 本身，所以忽略错误。
	if out, err := r.run("rev-list", "--left-right", "--count", from+"..."+to); err == nil {
		if f := strings.Fields(out); len(f) == 2 {
			d.Behind, _ = strconv.Atoi(f[0])
			d.Ahead, _ = strconv.Atoi(f[1])
		}
	}

	// 结尾的 -- 是防止分支名和文件名撞名时 git 认不出该按哪个解释。
	patch, err := r.runBytes("diff", "--no-color", "--find-renames", from, to, "--")
	if err != nil {
		return nil, err
	}
	// 只出文件清单，逐行内容交给 RangeFileDiff 按需取，原因见 parseDiffStats。
	d.Files = parseDiffStats(string(patch))
	return d, nil
}

// RangeFileDiff 取两个版本之间某一个文件的逐行差异。
//
// origPath 是这个文件在旧版本里的路径，只有发生过重命名时才不为空：
// 单独限定一个路径去 diff，git 是认不出重命名的（会当成一新一删），
// 把两侧路径都给它才能还原成一次重命名。
func (r *Repo) RangeFileDiff(from, to, path, origPath string) ([]DiffFile, error) {
	args := []string{"diff", "--no-color", "--find-renames", from, to, "--", path}
	if origPath != "" && origPath != path {
		args = append(args, origPath)
	}
	out, err := r.runBytes(args...)
	if err != nil {
		return nil, err
	}
	return parseUnifiedDiff(string(out)), nil
}

// FileDiff 读取工作区里单个文件的 diff。
//
// staged 为 true 时看的是暂存区与 HEAD 的差异，否则是工作区与暂存区的差异。
func (r *Repo) FileDiff(path string, staged bool, untracked bool) ([]DiffFile, error) {
	if untracked && !staged {
		return r.untrackedDiff(path)
	}

	args := []string{"diff", "--no-color", "--find-renames"}
	if staged {
		args = append(args, "--cached")
	}
	args = append(args, "--", path)

	out, err := r.runBytes(args...)
	if err != nil {
		return nil, err
	}
	return parseUnifiedDiff(string(out)), nil
}

// untrackedDiff 把一个未跟踪的新文件呈现成"整个文件都是新增行"。
//
// git diff 看不到未跟踪文件，这里用 --no-index 跟 /dev/null 比一次。
// 注意 --no-index 在发现差异时退出码是 1，这属于正常输出而不是失败。
func (r *Repo) untrackedDiff(path string) ([]DiffFile, error) {
	out, err := r.runBytes("diff", "--no-index", "--no-color", "--", "/dev/null", path)
	if err != nil {
		var ge *ErrGit
		if !errors.As(err, &ge) || strings.TrimSpace(ge.Stderr) != "" {
			return nil, err
		}
	}
	files := parseUnifiedDiff(string(out))
	for i := range files {
		files[i].Path = path
		files[i].OrigPath = ""
		files[i].Status = "A"
	}
	return files, nil
}

// parseUnifiedDiff 解析 git 的 unified diff 输出（含逐行内容）。
//
// 所有切片都返回空数组而不是 nil：JSON 里 null 和 [] 对前端是两回事。
func parseUnifiedDiff(patch string) []DiffFile {
	return parseDiff(patch, false)
}

// parseDiffStats 只数出每个文件改了多少行，不保留逐行内容。
//
// 用在"比较两个版本"上：两个相隔很远的版本之间可能有上千个文件、几十万行
// （实测某仓库跨 500 个提交是 1094 个文件、25 万行），逐行内容一次性传给
// 浏览器会直接卡死。所以先只给文件清单，用户点开哪个文件再单独取那一个。
//
// 顺带一提，这里不受 maxDiffLinesPerFile 限制：不存内容就没有内存压力，
// 统计数字反而比含内容那条路径更准。
func parseDiffStats(patch string) []DiffFile {
	return parseDiff(patch, true)
}

func parseDiff(patch string, statsOnly bool) []DiffFile {
	files := []DiffFile{}
	var cur *DiffFile
	var hunk *Hunk
	oldLine, newLine := 0, 0

	flushHunk := func() {
		if cur != nil && hunk != nil {
			// 只统计的时候不留 hunk，Hunks 保持空数组。
			if !statsOnly {
				cur.Hunks = append(cur.Hunks, *hunk)
			}
			hunk = nil
		}
	}
	flushFile := func() {
		flushHunk()
		if cur != nil {
			files = append(files, *cur)
			cur = nil
		}
	}

	lines := strings.Split(patch, "\n")
	for _, line := range lines {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			flushFile()
			a, b := parseDiffGitHeader(line)
			cur = &DiffFile{Path: b, Status: "M", Hunks: []Hunk{}}
			if a != b && a != "" {
				cur.OrigPath = a
			}

		case cur == nil:
			// 文件头之前的内容（比如 commit 头），忽略。
			continue

		case strings.HasPrefix(line, "new file mode"):
			cur.Status = "A"
		case strings.HasPrefix(line, "deleted file mode"):
			cur.Status = "D"
		case strings.HasPrefix(line, "rename from "):
			cur.Status = "R"
			cur.OrigPath = strings.TrimPrefix(line, "rename from ")
		case strings.HasPrefix(line, "rename to "):
			cur.Status = "R"
			cur.Path = strings.TrimPrefix(line, "rename to ")
		case strings.HasPrefix(line, "copy from "):
			cur.Status = "C"
			cur.OrigPath = strings.TrimPrefix(line, "copy from ")
		case strings.HasPrefix(line, "Binary files ") || strings.HasPrefix(line, "GIT binary patch"):
			cur.Binary = true

		case strings.HasPrefix(line, "@@"):
			flushHunk()
			o, n, header := parseHunkHeader(line)
			oldLine, newLine = o, n
			hunk = &Hunk{Header: header, Lines: []DiffLine{}}

		case hunk == nil:
			// index / --- / +++ 这些行不需要展示。
			continue

		case strings.HasPrefix(line, "\\"):
			// "\ No newline at end of file"
			continue

		default:
			if statsOnly {
				// 只数增删行数，内容一概不留。
				switch {
				case strings.HasPrefix(line, "+"):
					cur.Additions++
				case strings.HasPrefix(line, "-"):
					cur.Deletions++
				}
				continue
			}
			if cur.Truncated {
				continue
			}
			total := 0
			for _, h := range cur.Hunks {
				total += len(h.Lines)
			}
			if total+len(hunk.Lines) >= maxDiffLinesPerFile {
				cur.Truncated = true
				continue
			}

			var dl DiffLine
			switch {
			case strings.HasPrefix(line, "+"):
				dl = DiffLine{Kind: "add", NewLine: newLine, Text: line[1:]}
				newLine++
				cur.Additions++
			case strings.HasPrefix(line, "-"):
				dl = DiffLine{Kind: "del", OldLine: oldLine, Text: line[1:]}
				oldLine++
				cur.Deletions++
			case strings.HasPrefix(line, " "):
				dl = DiffLine{Kind: "ctx", OldLine: oldLine, NewLine: newLine, Text: line[1:]}
				oldLine++
				newLine++
			default:
				if line == "" {
					continue
				}
				dl = DiffLine{Kind: "ctx", OldLine: oldLine, NewLine: newLine, Text: line}
				oldLine++
				newLine++
			}
			if !utf8.ValidString(dl.Text) {
				dl.Text = strings.ToValidUTF8(dl.Text, "�")
			}
			hunk.Lines = append(hunk.Lines, dl)
		}
	}
	flushFile()
	return files
}

// parseDiffGitHeader 从 "diff --git a/x b/y" 里取出两侧路径。
func parseDiffGitHeader(line string) (string, string) {
	rest := strings.TrimPrefix(line, "diff --git ")
	// 路径可能含空格，用 " b/" 作为分界点；带引号的路径由 git 转义，这里保守处理。
	if i := strings.Index(rest, " b/"); i > 0 {
		a := strings.TrimPrefix(rest[:i], "a/")
		b := strings.TrimPrefix(rest[i+1:], "b/")
		return unquotePath(a), unquotePath(b)
	}
	return "", unquotePath(rest)
}

// unquotePath 还原 git 对特殊字符路径加的引号。
func unquotePath(p string) string {
	p = strings.TrimSpace(p)
	if len(p) >= 2 && p[0] == '"' && p[len(p)-1] == '"' {
		if s, err := strconv.Unquote(p); err == nil {
			return s
		}
		return p[1 : len(p)-1]
	}
	return p
}

// parseHunkHeader 解析 "@@ -a,b +c,d @@ ctx" 里的起始行号。
func parseHunkHeader(line string) (oldStart, newStart int, header string) {
	end := strings.Index(line[2:], "@@")
	if end < 0 {
		return 1, 1, line
	}
	spec := line[2 : end+2]
	header = strings.TrimSpace(line[end+4:])
	if header == "" {
		// 没有函数上下文时，退而显示行号范围，总比空着强。
		header = strings.TrimSpace(spec)
	}

	oldStart, newStart = 1, 1
	for _, part := range strings.Fields(spec) {
		if len(part) < 2 {
			continue
		}
		nums := strings.SplitN(part[1:], ",", 2)
		v, err := strconv.Atoi(nums[0])
		if err != nil {
			continue
		}
		switch part[0] {
		case '-':
			oldStart = v
		case '+':
			newStart = v
		}
	}
	return oldStart, newStart, header
}
