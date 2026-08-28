package git

import (
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

func TestDiffOptionsArgs(t *testing.T) {
	if got := (DiffOptions{}).args(); len(got) != 0 {
		t.Errorf("默认不该加参数，得到 %v", got)
	}
	if got := (DiffOptions{IgnoreWhitespace: true}).args(); !reflect.DeepEqual(got, []string{"-b"}) {
		t.Errorf("忽略空白应该加 -b，得到 %v", got)
	}
}

// 忽略空白那个参数必须排在 refs 和结尾的 -- 前面。
//
// 掉到 -- 后面的话 git 会把它当文件名：命令照样退出码 0、界面上没有任何变化、
// 也没有任何报错，是最难查的一种失效。所以这条单独钉死。
//
// ⚠️ 这个测试**必须直接检验三个 builder 的真实返回值**。早先那版是自己在测试里重新
// 拼一遍参数（而且拼对了），于是三个真实调用点把 -b 追加到了 -- 后面、开关整个失效，
// 测试却一路全绿。检验对象写错，比没有测试更糟——它给的是假的安全感。
// 加新的 diff 开关时，把它加进 wantFlags 就行，位置由这里保证。
func TestIgnoreWhitespaceFlagPosition(t *testing.T) {
	opt := DiffOptions{IgnoreWhitespace: true}

	// 键是场景名，值是**生产代码真正会执行的**那个拼装函数的返回值。
	cases := map[string][]string{
		"commit":        commitFilePatchArgs("abc123", "a.go", "", opt),
		"commit+rename": commitFilePatchArgs("abc123", "new.go", "old.go", opt),
		"range":         rangeFilePatchArgs("old", "new", "a.go", "", opt),
		"work":          workFilePatchArgs("a.go", "", false, opt),
		"work+staged":   workFilePatchArgs("a.go", "", true, opt),
		"work+rename":   workFilePatchArgs("new.go", "old.go", true, opt),
	}
	for name, args := range cases {
		t.Run(name, func(t *testing.T) {
			flagAt, sepAt := -1, -1
			for i, a := range args {
				if a == ignoreWhitespaceFlag && flagAt < 0 {
					flagAt = i
				}
				if a == "--" && sepAt < 0 {
					sepAt = i
				}
			}
			switch {
			case flagAt < 0:
				t.Errorf("%s 没出现在参数里：%v", ignoreWhitespaceFlag, args)
			case sepAt < 0:
				t.Errorf("缺少 -- 分隔符：%v", args)
			case flagAt > sepAt:
				t.Errorf("%s 落到了 -- 后面（git 会把它当文件名，静默失效）：%v", ignoreWhitespaceFlag, args)
			}
		})
	}
}

// 不开忽略空白时，三个 builder 一个多余参数都不该加。
func TestFilePatchArgsWithoutOptions(t *testing.T) {
	for name, args := range map[string][]string{
		"commit": commitFilePatchArgs("abc123", "a.go", "", DiffOptions{}),
		"range":  rangeFilePatchArgs("old", "new", "a.go", "", DiffOptions{}),
		"work":   workFilePatchArgs("a.go", "", false, DiffOptions{}),
	} {
		if contains(args, ignoreWhitespaceFlag) {
			t.Errorf("%s：没开开关却带上了 %s：%v", name, ignoreWhitespaceFlag, args)
		}
		if args[len(args)-1] != "a.go" {
			t.Errorf("%s：路径必须排在最后：%v", name, args)
		}
	}
}

func TestPatchArgs(t *testing.T) {
	got := commitPatchArgs("abc123", DiffOptions{IgnoreWhitespace: true})
	if got[len(got)-1] != "abc123" {
		t.Errorf("提交号必须排在最后，得到 %v", got)
	}
	if !contains(got, "-b") || !contains(got, "--first-parent") {
		t.Errorf("缺参数：%v", got)
	}

	got = rangePatchArgs("old", "new", DiffOptions{})
	if contains(got, "-b") {
		t.Errorf("没开忽略空白时不该有 -b：%v", got)
	}
	if got[len(got)-2] != "old" || got[len(got)-1] != "new" {
		t.Errorf("两个版本必须按 from、to 的顺序排在最后：%v", got)
	}

	// 没重命名时只给一个路径；重命名了要把两侧路径都给 git，否则它认不出这是重命名。
	if got := pathspec("a.go", ""); !reflect.DeepEqual(got, []string{"--", "a.go"}) {
		t.Errorf("pathspec = %v", got)
	}
	if got := pathspec("new.go", "old.go"); !reflect.DeepEqual(got, []string{"--", "new.go", "old.go"}) {
		t.Errorf("pathspec = %v", got)
	}
	if got := pathspec("same.go", "same.go"); !reflect.DeepEqual(got, []string{"--", "same.go"}) {
		t.Errorf("两侧路径一样时不该重复给：%v", got)
	}
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}

func TestParseDiffStats(t *testing.T) {
	patch := strings.Join([]string{
		"diff --git a/keep.go b/keep.go",
		"index 111..222 100644",
		"--- a/keep.go",
		"+++ b/keep.go",
		"@@ -1,3 +1,4 @@ func main()",
		" ctx",
		"-old line",
		"+new line",
		"+extra line",
		" tail",
		"diff --git a/gone.txt b/gone.txt",
		"deleted file mode 100644",
		"index 333..0000000",
		"--- a/gone.txt",
		"+++ /dev/null",
		"@@ -1 +0,0 @@",
		"-bye",
		"diff --git a/fresh.txt b/fresh.txt",
		"new file mode 100644",
		"index 0000000..444",
		"--- /dev/null",
		"+++ b/fresh.txt",
		"@@ -0,0 +1 @@",
		"+hi",
		"diff --git a/before.go b/after.go",
		"similarity index 95%",
		"rename from before.go",
		"rename to after.go",
		"diff --git a/logo.png b/logo.png",
		"index 555..666 100644",
		"Binary files a/logo.png and b/logo.png differ",
		"",
	}, "\n")

	files := parseDiffStats(patch)
	if len(files) != 5 {
		t.Fatalf("期望 5 个文件，得到 %d 个：%+v", len(files), files)
	}

	want := []DiffFile{
		{Path: "keep.go", Status: "M", Additions: 2, Deletions: 1},
		{Path: "gone.txt", Status: "D", Additions: 0, Deletions: 1},
		{Path: "fresh.txt", Status: "A", Additions: 1, Deletions: 0},
		{Path: "after.go", OrigPath: "before.go", Status: "R"},
		{Path: "logo.png", Status: "M", Binary: true},
	}
	for i, w := range want {
		if !reflect.DeepEqual(files[i], w) {
			t.Errorf("第 %d 个文件 = %+v，期望 %+v", i, files[i], w)
		}
	}
}

// --- a/x 和 +++ b/x 这两行也以 - + 开头，绝不能被当成增删行数进去。
func TestParseDiffStatsIgnoresFileHeaders(t *testing.T) {
	patch := strings.Join([]string{
		"diff --git a/x.go b/x.go",
		"index 111..222 100644",
		"--- a/x.go",
		"+++ b/x.go",
		"@@ -1 +1 @@",
		"-a",
		"+b",
		"",
	}, "\n")
	files := parseDiffStats(patch)
	if len(files) != 1 {
		t.Fatalf("期望 1 个文件，得到 %d 个", len(files))
	}
	if files[0].Additions != 1 || files[0].Deletions != 1 {
		t.Errorf("行数被文件头污染了：+%d -%d", files[0].Additions, files[0].Deletions)
	}
}

// git 关掉 core.quotePath 之后中文路径是原样输出的，但含引号 / 制表符的路径
// 照样会被引起来并转义。四种组合（两侧都引、都不引、各引一侧）都得认得出来。
func TestParseDiffGitHeader(t *testing.T) {
	cases := []struct {
		name    string
		line    string
		wantOld string
		wantNew string
	}{
		{"普通路径", `diff --git a/x.go b/x.go`, "x.go", "x.go"},
		{"路径含空格", `diff --git a/has space.txt b/has space.txt`, "has space.txt", "has space.txt"},
		{"中文路径（已关 quotePath，原样输出）", `diff --git a/中文.txt b/中文.txt`, "中文.txt", "中文.txt"},
		{"重命名", `diff --git a/before.go b/after.go`, "before.go", "after.go"},
		{"两侧都带引号", `diff --git "a/quo\"te.txt" "b/quo\"te.txt"`, `quo"te.txt`, `quo"te.txt`},
		{"只有新的一侧带引号", `diff --git a/plain.txt "b/quo\"te.txt"`, "plain.txt", `quo"te.txt`},
		{"只有旧的一侧带引号", `diff --git "a/quo\"te.txt" b/plain.txt`, `quo"te.txt`, "plain.txt"},
		{"路径本身以 a/ 开头", `diff --git a/a/nested.go b/a/nested.go`, "a/nested.go", "a/nested.go"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotOld, gotNew := parseDiffGitHeader(c.line)
			if gotOld != c.wantOld || gotNew != c.wantNew {
				t.Errorf("= %q / %q，期望 %q / %q", gotOld, gotNew, c.wantOld, c.wantNew)
			}
		})
	}
}

func TestParseDiffStatsQuotedPath(t *testing.T) {
	patch := "diff --git \"a/tab\\tname.txt\" \"b/tab\\tname.txt\"\n" +
		"index 111..222 100644\n@@ -1 +1 @@\n-a\n+b\n"
	files := parseDiffStats(patch)
	if len(files) != 1 || files[0].Path != "tab\tname.txt" {
		t.Errorf("带引号的路径没还原：%+v", files)
	}
}

func TestParseDiffStatsEmpty(t *testing.T) {
	// 开了忽略空白之后，只改了空白的文件 git 会一个字都不输出，这里要稳稳地返回空数组。
	if got := parseDiffStats(""); got == nil || len(got) != 0 {
		t.Errorf("空输入该返回空数组（不是 nil），得到 %#v", got)
	}
}

func TestTruncatePatch(t *testing.T) {
	small := "a\nb\nc\n"
	if got, cut := truncatePatch(small); got != small || cut {
		t.Errorf("没超上限不该动：%q %v", got, cut)
	}

	big := strings.Repeat("+line\n", maxPatchLines+500)
	got, cut := truncatePatch(big)
	if !cut {
		t.Error("超上限了却没标记截断")
	}
	if n := strings.Count(got, "\n"); n != maxPatchLines {
		t.Errorf("截断后应剩 %d 行，得到 %d 行", maxPatchLines, n)
	}
	if !strings.HasSuffix(got, "\n") {
		t.Error("截断必须切在整行边界上，不能留半行")
	}

	// 二进制或乱码文件里的非法字节要洗掉，否则 JSON 序列化出来的东西对不上。
	//
	// ⚠️ 这里必须按**字节**断言。早先写的是 strings.ContainsRune(dirty, 0xFF)，
	// 而 0xFF 作为 rune 是 U+00FF、在 UTF-8 里是 C3 BF 两个字节，跟样本里的裸字节 FF
	// 根本不是一回事——那个断言恒为 false，把洗字节的代码整段删掉它也照样绿。
	// 直接比最终结果，顺带把"连续非法字节合并成一个替换符"这个行为也钉住。
	dirty, _ := truncatePatch("+ok\xff\xfe\n")
	if dirty != "+ok\uFFFD\n" {
		t.Errorf("非法字节没洗干净：%q", dirty)
	}
}

// 忽略注释那组 -I 参数同样必须待在选项区。
//
// 跟 -b 一模一样的坑：-I 落到 -- 后面，git 把它和它后面那条正则一起当成文件名，
// 退出码 0、不报错、开关静默失效。实测确认过，所以这条也钉死。
// 这里连"两个开关同时开"的组合一起测——真实使用里它们本来就可以同时勾上。
func TestIgnoreCommentsFlagPosition(t *testing.T) {
	for name, opt := range map[string]DiffOptions{
		"仅注释":   {IgnoreComments: true},
		"空白+注释": {IgnoreWhitespace: true, IgnoreComments: true},
	} {
		for scene, args := range map[string][]string{
			"commit": commitFilePatchArgs("abc123", "a.go", "", opt),
			"range":  rangeFilePatchArgs("old", "new", "a.go", "", opt),
			"work":   workFilePatchArgs("a.go", "", true, opt),
		} {
			sepAt := len(args)
			for i, a := range args {
				if a == "--" {
					sepAt = i
					break
				}
			}
			n := 0
			for i, a := range args {
				if a != ignoreCommentsFlag {
					continue
				}
				n++
				if i > sepAt {
					t.Errorf("%s/%s：%s 落到了 -- 后面（静默失效）：%v", name, scene, ignoreCommentsFlag, args)
				}
				// -I 后面必须紧跟一条正则，不能是另一个参数或者结尾。
				if i+1 >= len(args) || strings.HasPrefix(args[i+1], "-") {
					t.Errorf("%s/%s：%s 后面没跟上正则：%v", name, scene, ignoreCommentsFlag, args)
				}
			}
			if n != len(commentLinePatterns) {
				t.Errorf("%s/%s：期望 %d 个 %s，实际 %d 个", name, scene, len(commentLinePatterns), ignoreCommentsFlag, n)
			}
		}
	}
}

// 注释模式必须是 git 认得的 POSIX 扩展正则，而且"宁可漏藏、绝不误藏"——
// 下面这些是真代码，一条都不许被当成注释。
func TestCommentPatternsNeverMatchCode(t *testing.T) {
	code := []string{
		"#include <stdio.h>", "#define MAX 10", "#dDiff { color: red; }",
		"*ptr = 5", "*p := &x", "---", "----", "--force-with-lease",
		"x := 1 // 行尾注释", `print('# 不是注释')`, "y := 2", "}", "",
	}
	res := make([]*regexp.Regexp, 0, len(commentLinePatterns))
	for _, p := range commentLinePatterns {
		re, err := regexp.CompilePOSIX(p)
		if err != nil {
			t.Fatalf("正则编不过 %q: %v", p, err)
		}
		res = append(res, re)
	}
	for _, line := range code {
		for i, re := range res {
			if re.MatchString(line) {
				t.Errorf("真代码被当成注释了：%q 命中 %q", line, commentLinePatterns[i])
			}
		}
	}

	// 反面：这些确实是注释，至少要被一条模式认出来。
	comments := []string{
		"// go", "  // 带缩进", "# shell", "## markdown", "#!/bin/bash",
		"/* 块注释", " * 续行", " */", "-- sql", "<!-- html -->",
	}
	for _, line := range comments {
		hit := false
		for _, re := range res {
			if re.MatchString(line) {
				hit = true
				break
			}
		}
		if !hit {
			t.Errorf("注释没被认出来：%q", line)
		}
	}
}

// 暂存过的重命名必须把两侧路径都给 git，否则它认不出是重命名、
// 会把整个文件当成新增行显示出来（用户实际会碰到：改个文件名 + 点 Stage 就复现）。
func TestWorkFilePatchArgsRename(t *testing.T) {
	got := workFilePatchArgs("new.go", "old.go", true, DiffOptions{})
	if n := len(got); got[n-3] != "--" || got[n-2] != "new.go" || got[n-1] != "old.go" {
		t.Errorf("重命名要给两侧路径：%v", got)
	}

	// 没重命名时不许多给一个路径，否则 git 会把它当成第二个 pathspec。
	got = workFilePatchArgs("a.go", "", true, DiffOptions{})
	if n := len(got); got[n-2] != "--" || got[n-1] != "a.go" {
		t.Errorf("没重命名时只该给一个路径：%v", got)
	}
}

// rename / copy 行上的路径也会被 git 加引号转义，必须还原。
// 而且不能用会 TrimSpace 的那个版本——结尾真带空格的文件名 git 不加引号，一 trim 就错。
func TestParseDiffStatsQuotedRename(t *testing.T) {
	patch := strings.Join([]string{
		`diff --git "a/old	name.txt" "b/new	name.txt"`,
		"similarity index 95%",
		`rename from "old	name.txt"`,
		`rename to "new	name.txt"`,
		"",
	}, "\n")
	files := parseDiffStats(patch)
	if len(files) != 1 {
		t.Fatalf("期望 1 个文件，得到 %d 个", len(files))
	}
	if files[0].Path != "new\tname.txt" || files[0].OrigPath != "old\tname.txt" {
		t.Errorf("带引号的重命名路径没还原：%+v", files[0])
	}
	if files[0].Status != "R" {
		t.Errorf("状态应为 R，得到 %q", files[0].Status)
	}
}

func TestUnquoteIfQuotedKeepsTrailingSpace(t *testing.T) {
	// git 对结尾带空格的文件名是不加引号的，所以这里一个字符都不该动。
	if got := unquoteIfQuoted("trailing .txt "); got != "trailing .txt " {
		t.Errorf("结尾空格被吃掉了：%q", got)
	}
	if got := unquoteIfQuoted(`"quo\"te.txt"`); got != `quo"te.txt` {
		t.Errorf("引号没还原：%q", got)
	}
}

// 未跟踪文件那条路是用 git diff --no-index 走文件系统的，没有 git 自己的"越出仓库就拒绝"
// 兜底，所以路径约束得自己做。
//
// ⚠️ 这个测试盯的是一个真踩过的坑：第一版校验的是 filepath.Join(dir, path)，而绝对路径
// Join 之后会变成 <repo>/etc/hosts —— 检查通过了，可传给 git 的仍是原始的 /etc/hosts，
// 等于没拦。校验的对象必须和交给 git 的那个是同一个。
func TestUntrackedPatchRejectsOutsidePaths(t *testing.T) {
	repo := &Repo{Dir: t.TempDir()}
	for _, p := range []string{
		"/etc/hosts",
		"/Users/somebody/.gitconfig",
		"../outside.txt",
		"../../etc/hosts",
		"sub/../../outside.txt",
	} {
		if _, _, err := repo.untrackedPatch(p); err == nil {
			t.Errorf("越界路径没被拦住：%q", p)
		}
	}
}

// git status 会把嵌套仓库、以及指向目录的软链当成一条"目录"记录列出来，
// 直接丢给 --no-index 会报一个根本不存在的文件名，看着像内部错误。
func TestUntrackedPatchRejectsDirectory(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	repo := &Repo{Dir: dir}
	_, _, err := repo.untrackedPatch("nested")
	if err == nil {
		t.Fatal("目录没被拦住")
	}
	if !strings.Contains(err.Error(), "nested repository") {
		t.Errorf("报错该说人话，得到：%v", err)
	}
}

// boundedBuffer 只收前 max 字节，但必须始终报告"全部写入"——
// 返回 n < len(p) 会被 os/exec 当成 io 错误，把整条 git 命令判失败。
func TestBoundedBuffer(t *testing.T) {
	b := &boundedBuffer{max: 10}
	n, err := b.Write([]byte("0123456789ABCDEF"))
	if n != 16 || err != nil {
		t.Fatalf("必须报告全部写入：n=%d err=%v", n, err)
	}
	if got := b.buf.String(); got != "0123456789" {
		t.Errorf("只该留前 10 字节，得到 %q", got)
	}
	if !b.overrun {
		t.Error("超限了却没标记")
	}

	// 再写还是不报错，也不再攒。
	if n, err := b.Write([]byte("more")); n != 4 || err != nil || b.buf.Len() != 10 {
		t.Errorf("满了之后不该再攒：n=%d err=%v len=%d", n, err, b.buf.Len())
	}

	// 没到上限时不该标记截断。
	small := &boundedBuffer{max: 10}
	small.Write([]byte("abc"))
	if small.overrun {
		t.Error("没超限却标了截断")
	}
}

// runLines 是流式读的，超长行（压缩过的 JS、单行 JSON、CSV）在缓冲区里放不下，
// 会被分成好几段读出来。⚠️ 这时候**只能喂第一段**，剩下的必须丢掉——
// 每段都喂的话，一行会被数成好几行，行数统计直接错。这个测试就钉这一条。
func TestCommitDetailCountsLongLinesOnce(t *testing.T) {
	dir := t.TempDir()
	repo := &Repo{Dir: dir}
	run := func(args ...string) {
		t.Helper()
		if _, err := repo.run(append([]string{"-c", "user.email=t@t", "-c", "user.name=t"}, args...)...); err != nil {
			t.Fatalf("git %v: %v", args, err)
		}
	}
	if _, err := repo.run("init", "-q", "."); err != nil {
		t.Fatal(err)
	}
	// 三行：两行普通的，中间一行 512KB（远超 64KB 的读缓冲）。
	//
	// ⚠️ 内容故意用 '+'。用 'x' 之类的字符测不出问题：那样续段以 'x' 开头、
	// 本来就不匹配增删行的判断，就算每段都喂也不会多计，测试会假通过。
	// 换成 '+' 之后每一段都长得像"新增行"，喂错了立刻数错——base64、
	// 压缩过的 JS 里本来就到处是 '+'，这不是造出来的极端情况。
	long := strings.Repeat("+", 512*1024)
	body := "first\n" + long + "\nlast\n"
	if err := os.WriteFile(filepath.Join(dir, "big.txt"), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "-A")
	run("commit", "-qm", "add big")

	head, err := repo.run("rev-parse", "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	d, err := repo.CommitDetail(strings.TrimSpace(head), DiffOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if len(d.Files) != 1 {
		t.Fatalf("期望 1 个文件，得到 %d 个：%+v", len(d.Files), d.Files)
	}
	// 三行新增，一行都不能多——多出来就说明超长行被数了不止一次。
	if got := d.Files[0].Additions; got != 3 {
		t.Errorf("超长行被重复计数了：新增 %d 行，期望 3 行", got)
	}
	if d.Files[0].Status != "A" || d.Files[0].Path != "big.txt" {
		t.Errorf("文件信息不对：%+v", d.Files[0])
	}
}
