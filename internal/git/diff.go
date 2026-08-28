package git

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// 这个文件负责两件事，分工是刻意的：
//
//   1. 文件清单 —— 哪些文件改了、各改了多少行。用 parseDiffStats 从 git 的输出里数出来。
//   2. 单个文件的改动明细 —— 直接把 git 的原始 patch 文本递给前端。
//
// 明细为什么不在这里解析成结构：前端用 diff2html 渲染，行内高亮、并排视图、
// 语法着色都是它的事，它要的输入就是 git 原样的 unified diff 文本。
// 我们再解析一遍只会多一层可能出错的翻译。

// CommitDetail 是点开一个提交后看到的全部信息。
type CommitDetail struct {
	Commit
	Body       string     `json:"body"`
	CommitDate int64      `json:"commitDate"`
	Files      []DiffFile `json:"files"`
}

// DiffFile 是文件清单里的一条：这个文件怎么变的、变了多少。
//
// 不含逐行内容——那个按需去取，见 FilePatch。
type DiffFile struct {
	Path     string `json:"path"`
	OrigPath string `json:"origPath,omitempty"`
	// Status: A 新增 / M 修改 / D 删除 / R 重命名 / C 拷贝
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	Binary    bool   `json:"binary"`
}

// maxPatchLines 是单个文件的 patch 返回给前端的行数上限。
//
// 超大文件（生成的代码、锁文件、整份被重写的文件）一次几万行画成 DOM 会把浏览器卡死，
// 并排视图还要再翻一倍。截断的是尾部，`diff --git` 那几行文件头留着，
// diff2html 照样认得出这是哪个文件、什么语言。
const maxPatchLines = 4000

// maxPatchBytes 是单次取 patch 最多从 git 收多少字节。
//
// 按行数拦不住"行数不多但每行极长"的文件（压缩过的 JS、单行 JSON、CSV），
// 所以再加一道字节闸。8MB 对 4000 行来说是每行 2KB，正常代码远远用不到；
// 到顶了就跟行数超限一样标 truncated，界面上照样有提示。
const maxPatchBytes = 8 << 20

// DiffOptions 控制 diff 怎么算，所有取 diff 的地方都吃它。
type DiffOptions struct {
	// IgnoreWhitespace 对应界面上的 "Ignore whitespace"：只有空白不一样的行当成没变。
	// 一整段代码只是调了缩进时，打开它就只剩下真正的改动。
	//
	// 注意它的连带效果：整个文件只有空白改动时，git 会把这个文件从输出里整个拿掉，
	// 文件清单里也就看不到它了。这是 git 的行为，不是我们漏了，界面上要说清楚。
	IgnoreWhitespace bool

	// IgnoreComments 对应界面上的 "Ignore comments"：整段只改了注释的地方当成没变。
	//
	// ⚠️ 它不是逐行判的，能藏掉多少取决于**离最近的代码改动有多远**。实测规律：
	// 一处纯注释改动，只有当它与最近的代码改动之间隔着的未改动行数 >= diff 的上下文
	// 行数（默认 3）时才会被藏掉；更近的话，它落在那处代码改动必须显示的上下文窗口
	// 里面，git 只能连它一起显示。（把 -U5 传进去，这个边界就跟着变成 5，验证过。）
	// 所以"整段扫了一遍注释"这类提交效果最好，而紧贴着代码改的那一行注释藏不掉。
	// `x := 1 // 改了行尾注释` 这种也藏不掉，那行有代码，本来也不该藏。
	//
	// 跟 IgnoreWhitespace 一样：整个文件只有注释改动时，这个文件会从 git 输出里
	// 整个消失，文件清单里也就看不到了，界面上得靠文案说清楚。
	IgnoreComments bool
}

// ignoreWhitespaceFlag 是"忽略空白"用的 git 参数。
//
// ⚠️ 用 -b（--ignore-space-change）而不是更狠的 -w（--ignore-all-space），这是有意的：
// -w 连"一边有空白、另一边完全没有"都当成一样，于是**字符串字面量里的空格被删掉也会被藏起来**。
// 实测 `msg := "hello world"` 改成 `msg := "helloworld"`，-w 下 git 输出 0 字节——
// 一个改了分隔符或正则的提交，勾着这个开关做 review 会一个字都看不到。看 diff 的工具
// 绝不能这样悄悄吞掉真实改动。
//
// -b 把"一段空白"和"另一段空白"看作等价，所以缩进层级改了、tab 换成空格、行尾多了空格，
// 照样全部隐藏——用户抱怨的那几种情形一个不落。它唯一盖不住的是
// "原本顶格、现在被包进一层缩进"，而那种情况包裹它的那几行本来就会显示出来，不会漏审。
const ignoreWhitespaceFlag = "-b"

// ignoreCommentsFlag 是"忽略注释"用的 git 参数，值是一条正则，见 commentLinePatterns。
const ignoreCommentsFlag = "-I"

// commentLinePatterns 是"忽略注释"用的行模式，逐条通过 git 的 -I 传进去。
//
// git 的 -I<regex>（--ignore-matching-lines）本来就是干这个的，不用自己写注释解析器；
// 可以给多次，任意一条匹配即算注释行。用的是 POSIX 扩展正则，且我们跑 git 时
// 强制了 LC_ALL=C（见 exec.go），所以 [[:space:]] 是纯 ASCII 语义，行为稳定。
//
// ⚠️ 取舍跟 -b 而不是 -w 是同一个：**宁可漏藏，绝不误藏**。看 diff 的工具把一行真代码
// 悄悄吞掉，比多显示几行注释严重得多。所以下面几条都刻意收窄了：
//
//	#  后面必须跟空格 / # / ! / 行尾   —— 否则 #include、#define、CSS 的 #id 选择器会被当注释吞掉
//	*  后面必须跟空格或 /              —— 否则 *ptr = 5、*p := &x 这种解引用会被吞掉
//	-- 后面必须跟空格                  —— 否则 Markdown 的 ---、命令行的 --force 会被吞掉
//
// 这几条都是实测出来的：19 个样本（9 个该藏 + 10 个绝不能藏，含上面每一种）跑下来
// 零漏藏、零误藏；拿 twig 自己的改动跑，被藏的行也全部确实是注释。
var commentLinePatterns = []string{
	`^[[:space:]]*//`,                   // Go / JS / Java / Rust / proto / C 系行注释
	`^[[:space:]]*#([[:space:]]|#|!|$)`, // Python / shell / YAML / Makefile / Dockerfile
	`^[[:space:]]*/\*`,                  // C 系块注释开头
	`^[[:space:]]*\*([[:space:]]|/|$)`,  // C 系块注释的续行与结尾
	`^[[:space:]]*--[[:space:]]`,        // SQL / Lua
	`^[[:space:]]*(<!--|-->)`,           // HTML / XML / Markdown
}

// args 返回要塞进 git 命令的参数。
//
// ⚠️ 调用方必须把它放在**选项区**——也就是排在 refs 和结尾的 `--` 前面。
// 落到 `--` 后面 git 会把它当成一个文件名：不报错、不生效，最糟的一种失败方式。
// 三个 *FilePatchArgs 纯函数就是为了保证这一点，别绕开它们自己拼参数。
func (o DiffOptions) args() []string {
	var args []string
	if o.IgnoreWhitespace {
		args = append(args, ignoreWhitespaceFlag)
	}
	if o.IgnoreComments {
		for _, p := range commentLinePatterns {
			args = append(args, ignoreCommentsFlag, p)
		}
	}
	return args
}

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

// CommitDetail 读取单个提交的详情与它改动的文件清单。
func (r *Repo) CommitDetail(hash string, opt DiffOptions) (*CommitDetail, error) {
	d, err := r.commitMeta(hash)
	if err != nil {
		return nil, err
	}
	// 边读边数，不把整份 patch 攒进内存——一个提交里加了个大文本文件时，
	// git 的输出能到几百 MB，而我们只要一串数字。
	var st diffStats
	if err := r.runLines(st.feed, commitPatchArgs(hash, opt)...); err != nil {
		return nil, err
	}
	d.Files = st.done()
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
func (r *Repo) RangeDiff(from, to string, opt DiffOptions) (*RangeDetail, error) {
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

	// 结尾的 -- 是防止分支名和文件名撞名时 git 认不出该按哪个解释（log.go 里同理）。
	// 它不能挪进 rangePatchArgs：RangeFilePatch 后面还要接 pathspec()，那里自带一个 --。
	// 同样边读边数，理由见 CommitDetail。
	var st diffStats
	if err := r.runLines(st.feed, append(rangePatchArgs(from, to, opt), "--")...); err != nil {
		return nil, err
	}
	// 两个相隔很远的版本之间可能有上千个文件、几十万行（实测某仓库跨 500 个提交是
	// 1094 个文件、25 万行），所以这里只数个数，逐行内容点开哪个文件再单独取。
	d.Files = st.done()
	return d, nil
}

// CommitFilePatch 取某一个提交里、某一个文件的原始 patch 文本。
func (r *Repo) CommitFilePatch(hash, path, origPath string, opt DiffOptions) (string, bool, error) {
	return r.patchText(commitFilePatchArgs(hash, path, origPath, opt))
}

// RangeFilePatch 取两个版本之间、某一个文件的原始 patch 文本。
func (r *Repo) RangeFilePatch(from, to, path, origPath string, opt DiffOptions) (string, bool, error) {
	return r.patchText(rangeFilePatchArgs(from, to, path, origPath, opt))
}

// WorkFilePatch 取工作区里某一个文件的原始 patch 文本。
//
// staged 为 true 时看的是暂存区与 HEAD 的差异，否则是工作区与暂存区的差异。
func (r *Repo) WorkFilePatch(path, origPath string, staged, untracked bool, opt DiffOptions) (string, bool, error) {
	if untracked && !staged {
		// 未跟踪的文件是跟 /dev/null 比，整份都是新增行，忽略空白在这里没有任何影响，不用传。
		return r.untrackedPatch(path)
	}
	return r.patchText(workFilePatchArgs(path, origPath, staged, opt))
}

// —— 单文件 patch 的参数拼装 ——
//
// ⚠️ 这三个函数存在的唯一理由，就是把 opt.args() 钉在**选项区**——排在结尾的 -- 前面。
// 早先的写法是 `append(某builder(…, DiffOptions{}), pathspec(…)...)` 再把 opt.args()
// 追加到最后，于是 -b 落到了 -- 后面：git 把它当成一个文件名，退出码 0、不报错、
// 开关完全失效，而文件清单那条路（走 builder，位置是对的）照常生效——
// 于是界面看着像好的，点开文件才是坏的，是最难查的一种失效。
//
// 拆成纯函数还有第二个作用：让 TestIgnoreWhitespaceFlagPosition 能检验**真实**的拼装结果。
// 早先那版测试自己又拼了一遍（而且拼对了），所以永远抓不到上面这个 bug。
// 以后再往 DiffOptions 里加开关，只要经过这里就自动待在正确的位置。

func commitFilePatchArgs(hash, path, origPath string, opt DiffOptions) []string {
	return append(commitPatchArgs(hash, opt), pathspec(path, origPath)...)
}

func rangeFilePatchArgs(from, to, path, origPath string, opt DiffOptions) []string {
	return append(rangePatchArgs(from, to, opt), pathspec(path, origPath)...)
}

func workFilePatchArgs(path, origPath string, staged bool, opt DiffOptions) []string {
	args := []string{"diff", "--no-color", "--find-renames"}
	args = append(args, opt.args()...)
	if staged {
		args = append(args, "--cached")
	}
	// 两侧路径都要给，否则 git 认不出这是重命名，会当成"整个文件新增"。
	// 暂存过的重命名（git status 里的 R）走的就是这条路，见 pathspec 的注释。
	return append(args, pathspec(path, origPath)...)
}

// commitPatchArgs 拼出"看一个提交"的 git 命令。
//
// 合并提交默认不产出 diff，用 -m 让它对第一个父提交出 diff。
func commitPatchArgs(hash string, opt DiffOptions) []string {
	args := []string{"show", "--no-color", "-m", "--first-parent", "--patch",
		"--find-renames", "--format="}
	args = append(args, opt.args()...)
	return append(args, hash)
}

// rangePatchArgs 拼出"比较两个版本"的 git 命令。
func rangePatchArgs(from, to string, opt DiffOptions) []string {
	args := []string{"diff", "--no-color", "--find-renames"}
	args = append(args, opt.args()...)
	return append(args, from, to)
}

// pathspec 把"只看这一个文件"的部分拼出来。
//
// 开头的 -- 是必须的：分支名和文件名可能撞名，没有它 git 认不出该按哪个解释；
// 它同时也让以 - 开头的文件名不会被当成参数（所以路径不需要另做过滤）。
//
// origPath 是这个文件在旧版本里的路径，只有发生过重命名时才不为空：
// 单独限定一个路径去 diff，git 是认不出重命名的（会当成一新一删），
// 把两侧路径都给它才能还原成一次重命名。
func pathspec(path, origPath string) []string {
	args := []string{"--", path}
	if origPath != "" && origPath != path {
		args = append(args, origPath)
	}
	return args
}

// patchText 跑一次 git 并把输出整理成能直接交给前端的 patch 文本。
//
// 用带上限的读法：反正只要开头 maxPatchLines 行，没必要把 git 的整份输出攒进内存。
// 上限按字节设在 maxPatchBytes，防的是"行数不多但每行极长"的情形（压缩过的 JS、
// 单行 JSON），那种光按行数拦不住。
func (r *Repo) patchText(args []string) (string, bool, error) {
	out, capped, err := r.runBytesLimit(maxPatchBytes, args...)
	if err != nil {
		return "", false, err
	}
	if capped {
		// 按字节切的，最后一行多半是半截的，退到上一个换行为止，
		// 免得把半行喂给 diff2html。
		if i := bytes.LastIndexByte(out, '\n'); i >= 0 {
			out = out[:i+1]
		}
	}
	patch, truncated := truncatePatch(string(out))
	return patch, truncated || capped, nil
}

// untrackedPatch 把一个未跟踪的新文件呈现成"整个文件都是新增行"。
//
// git diff 看不到未跟踪文件，这里用 --no-index 跟 /dev/null 比一次。
// 注意 --no-index 在发现差异时退出码是 1，这属于正常输出而不是失败。
func (r *Repo) untrackedPatch(path string) (string, bool, error) {
	// git status 会把**嵌套的 git 仓库**（vendored 依赖、随手 clone 的、没注册的 submodule）
	// 和指向目录的软链，当成一条"目录"记录列出来。直接丢给 --no-index，git 会拿 /dev/null
	// 去配 <dir>/null，报一个根本不存在的文件名，看着像内部错误。这里先拦掉，说句人话。
	//
	// 顺带把路径约束在仓库内：--no-index 是按文件系统路径解析的，不像其它两条路那样有
	// git 自己的"越出仓库就拒绝"兜底。正常调用的 path 都来自 git status，本来就在仓库内，
	// 这条只是防止以后有人从别处把路径传进来。
	//
	// ⚠️ 校验的对象必须和交给 git 的那个是同一个。第一版只校验了 filepath.Join(r.Dir, path)，
	// 而绝对路径经 Join 之后会变成 <repo>/etc/hosts —— 检查通过了，可传给 git 的仍是原始的
	// /etc/hosts，等于没拦。所以先把绝对路径直接拒掉，再查 .. 越界。
	// （path 正常都来自 git status，一定是仓库内的相对路径，这两条不会误伤。）
	if filepath.IsAbs(path) {
		return "", false, &ErrGit{Stderr: "path must be relative to the repository: " + path}
	}
	full := filepath.Join(r.Dir, path)
	rel, relErr := filepath.Rel(r.Dir, full)
	if relErr != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", false, &ErrGit{Stderr: "path is outside the repository: " + path}
	}
	if fi, err := os.Stat(full); err == nil && fi.IsDir() {
		return "", false, &ErrGit{Stderr: "this is a nested repository (or a link to a directory), not a file — open it as its own repository to see its changes"}
	}
	// ⚠️ 这里必须用带上限的读法，不能用 runBytes。工作区里放着一个几百 MB 的文本文件
	// （SQL dump、日志）时，--no-index 会把整份内容当成新增行吐出来——实测 300MB 的文件
	// 会把进程 RSS 顶到 700MB 以上，而我们最终只要开头 4000 行、响应才 242KB。
	// 这条路是最容易撞上的：工作区文件列表会自动选中第一个文件，点都不用点。
	out, capped, err := r.runBytesLimit(maxPatchBytes, "diff", "--no-index", "--no-color", "--", "/dev/null", path)
	if err != nil {
		var ge *ErrGit
		if !errors.As(err, &ge) || strings.TrimSpace(ge.Stderr) != "" {
			return "", false, err
		}
	}
	if capped {
		if i := bytes.LastIndexByte(out, '\n'); i >= 0 {
			out = out[:i+1]
		}
	}
	// 早先这里把 "--- a/dev/null" 改写成 "--- /dev/null"，已删掉：实测 git 2.50.1 的
	// --no-index 本来输出的就是标准的 "--- /dev/null"（根目录、子目录都一样），这个替换
	// 一次都不会触发。留着还有害——它是 Replace(..., 1)，只替换第一处出现的地方，而文件头
	// 里既然没有，唯一能命中的就是**文件内容里**恰好长这样的一行，等于把用户的内容改掉。
	p, truncated := truncatePatch(string(out))
	return p, truncated || capped, nil
}

// truncatePatch 把过大的 patch 截到 maxPatchLines 行，按整行切，不留半行。
func truncatePatch(patch string) (string, bool) {
	// git 的输出可能带非法字节（二进制、乱码的文件），JSON 装不下，先洗成合法 UTF-8。
	patch = strings.ToValidUTF8(patch, "�")

	cut := 0
	for n := 0; n < maxPatchLines; n++ {
		i := strings.IndexByte(patch[cut:], '\n')
		if i < 0 {
			return patch, false
		}
		cut += i + 1
	}
	if cut >= len(patch) {
		return patch, false
	}
	return patch[:cut], true
}

// parseDiffStats 从 git 的 patch 输出里数出文件清单：每个文件是什么状态、改了多少行。
//
// 这是 diffStats 的一次性封装，方便测试和小输入直接用。真正取 diff 的地方走
// 增量的 diffStats，不把整份 patch 攒进内存——原因见 diffStats 的注释。
func parseDiffStats(patch string) []DiffFile {
	var st diffStats
	for _, line := range strings.Split(patch, "\n") {
		st.feed(line)
	}
	return st.done()
}

// diffStats 一行一行地数文件清单，不需要先把整份 patch 拿在手里。
//
// 为什么要做成增量的：清单其实只是数个数，可 git 的 patch 输出能到几百 MB
// （某个提交里加了个大文本文件时）。先攒后解析等于为了一个几百字节的响应吃掉
// 几百 MB——实测某仓库里一个 200MB 的文件让进程 RSS 冲到 686MB，而响应只有 394 字节。
// 边读边数，内存占用就跟 patch 多大无关了。
//
// 解析规则跟以前一字未改，只是从"自己遍历切好的行"改成"外面喂行"。
type diffStats struct {
	files  []DiffFile
	cur    *DiffFile
	inHunk bool
}

func (st *diffStats) flush() {
	if st.cur != nil {
		st.files = append(st.files, *st.cur)
		st.cur = nil
	}
}

// done 收尾并交出结果。
//
// 一定返回非 nil 切片：Go 的 nil 切片会序列化成 JSON null，前端拿它取 .length 会直接炸。
func (st *diffStats) done() []DiffFile {
	st.flush()
	if st.files == nil {
		return []DiffFile{}
	}
	return st.files
}

func (st *diffStats) feed(line string) {
	switch {
	case strings.HasPrefix(line, "diff --git "):
		st.flush()
		st.inHunk = false
		a, b := parseDiffGitHeader(line)
		st.cur = &DiffFile{Path: b, Status: "M"}
		if a != b && a != "" {
			st.cur.OrigPath = a
		}

	case st.cur == nil:
		// 文件头之前的内容（比如 commit 头），忽略。
		return

	case strings.HasPrefix(line, "@@"):
		st.inHunk = true

	case !st.inHunk:
		// index / --- / +++ 这些行也以 + - 开头，不能拿去数行数，
		// 所以要等看到 @@ 才开始数。
		switch {
		case strings.HasPrefix(line, "new file mode"):
			st.cur.Status = "A"
		case strings.HasPrefix(line, "deleted file mode"):
			st.cur.Status = "D"
		// ⚠️ 这三行的路径也会被 git 加引号转义（名字里有引号 / 反斜杠 / 制表符 / 换行时），
		// 必须还原，否则清单里显示的是转义后的乱名、点开还找不到文件。
		// 不能直接用 unquotePath —— 它会 TrimSpace，而结尾真带空格的文件名 git 是不加
		// 引号的，一 trim 就把名字改错了。
		case strings.HasPrefix(line, "rename from "):
			st.cur.Status = "R"
			st.cur.OrigPath = unquoteIfQuoted(strings.TrimPrefix(line, "rename from "))
		case strings.HasPrefix(line, "rename to "):
			st.cur.Status = "R"
			st.cur.Path = unquoteIfQuoted(strings.TrimPrefix(line, "rename to "))
		case strings.HasPrefix(line, "copy from "):
			st.cur.Status = "C"
			st.cur.OrigPath = unquoteIfQuoted(strings.TrimPrefix(line, "copy from "))
		case strings.HasPrefix(line, "Binary files "), strings.HasPrefix(line, "GIT binary patch"):
			st.cur.Binary = true
		}

	case strings.HasPrefix(line, "+"):
		st.cur.Additions++
	case strings.HasPrefix(line, "-"):
		st.cur.Deletions++
	}
}

// parseDiffGitHeader 从 "diff --git a/x b/y" 这一行里取出两侧路径。
//
// 顺序很讲究：**先去引号、再去 a/ b/ 前缀**。反过来的话，
// 遇到 "a/x.txt" 这种被引起来的路径，前缀就藏在引号后面，剥不掉。
func parseDiffGitHeader(line string) (string, string) {
	rest := strings.TrimPrefix(line, "diff --git ")
	a, b, ok := splitTwoPaths(rest)
	if !ok {
		return "", stripSidePrefix(unquotePath(rest))
	}
	return stripSidePrefix(unquotePath(a)), stripSidePrefix(unquotePath(b))
}

// splitTwoPaths 把 "diff --git " 后面那截切成两个路径。
//
// 要认四种组合：两侧都普通、两侧都带引号、以及一侧带引号一侧不带
// （重命名时一头是普通名、另一头带特殊字符就会这样）。
//
// ⚠️ 普通路径里的空格 git 是不转义的，所以"哪个空格才是分界点"本身就有歧义，
// 只能靠后半截以 b/ 开头这个特征去猜。文件名里真带 " b/" 的话就会猜错——
// 这是 diff 格式自身的毛病，绕不过去。
func splitTwoPaths(rest string) (string, string, bool) {
	if strings.HasPrefix(rest, `"`) {
		// 引号里的引号会被转义成 \"，扫的时候要跳过。
		for i := 1; i < len(rest); i++ {
			if rest[i] == '\\' {
				i++
				continue
			}
			if rest[i] == '"' {
				return rest[:i+1], strings.TrimSpace(rest[i+1:]), true
			}
		}
		return "", "", false
	}
	// 前半截没引号，后半截可能有：先找带引号的分界点，再找普通的。
	if i := strings.Index(rest, ` "b/`); i > 0 {
		return rest[:i], rest[i+1:], true
	}
	if i := strings.Index(rest, " b/"); i > 0 {
		return rest[:i], rest[i+1:], true
	}
	return "", "", false
}

// stripSidePrefix 去掉 git 给两侧路径加的 a/ b/ 前缀。
func stripSidePrefix(p string) string {
	if len(p) > 2 && (p[0] == 'a' || p[0] == 'b') && p[1] == '/' {
		return p[2:]
	}
	return p
}

// unquotePath 还原 git 对特殊字符路径加的引号。
//
// 关掉 core.quotePath 之后中文之类的非 ASCII 路径已经是原样输出了，
// 但含引号、制表符、换行的路径 git 仍然会加引号并转义，这里还得管。
func unquotePath(p string) string {
	return unquoteIfQuoted(strings.TrimSpace(p))
}

// unquoteIfQuoted 只做"带引号就脱引号"，**不动首尾空白**。
//
// rename / copy 那几行用它而不是 unquotePath：那些行的路径是整行剩下的部分，
// 本来就没有多余空白，而文件名结尾真带空格时 git 不加引号，TrimSpace 会把名字改错。
func unquoteIfQuoted(p string) string {
	if len(p) >= 2 && p[0] == '"' && p[len(p)-1] == '"' {
		if s, err := strconv.Unquote(p); err == nil {
			return s
		}
		return p[1 : len(p)-1]
	}
	return p
}
