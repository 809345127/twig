package git

import (
	"reflect"
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
		"work":          workFilePatchArgs("a.go", false, opt),
		"work+staged":   workFilePatchArgs("a.go", true, opt),
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
		"work":   workFilePatchArgs("a.go", false, DiffOptions{}),
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
