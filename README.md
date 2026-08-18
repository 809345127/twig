# twig

一个精简的本地 Git 图形界面 —— SourceTree 的常用功能，加上它没有的那件事：

**提交图上画哪几条分支，你自己勾。**

分支一多，SourceTree 的图就糊成一团乱麻，而它只能"全画"或"不画"。twig 在左侧
每条分支前放了一个勾选框：勾上谁就只画谁，图立刻清爽下来。

界面文案一律用英文（git 术语翻成中文反而失真）。

## 长什么样

```
┌─ demo-repo  main ──── Fetch Pull Push① Branch Stash ──────────── Refresh ┐
├────────────────┬─────────────────────────────────────────────────────────┤
│ Working Copy 3 │  GRAPH  DESCRIPTION              AUTHOR  DATE    COMMIT  │
│                │  ○   Uncommitted changes (3 files)                       │
│ BRANCHES       │  ●   [main] Add release notes    Alice   Aug 9  211bd91  │
│  All None Curr │  │●  [release/1.1] Prepare 1.1   Alice   Aug 8  a53e6ba  │
│ ☐ feature/a    │  ●   Update changelog            Alice   Aug 7  b42c2a6  │
│ ☑ main         │  ●╮  [v1.0.0] Merge hotfix/crash Alice   Aug 6  7670f7a  │
│ ☑ release/1.1  │  │●  Fix startup crash           Alice   Aug 6  2d4c7b5  │
│                │  ●╯  Update docs                 Alice   Aug 5  a774e57  │
│ REMOTES   129  │                                                          │
│ TAGS       12  ├─────────────────────────────────────────────────────────┤
│ STASHES     0  │  提交详情 / 工作区暂存 + 提交框                             │
└────────────────┴─────────────────────────────────────────────────────────┘
```

## 跑起来

**方式一：双击图标（推荐）**

```bash
./packaging/make-app.sh -i      # 打包并装到 /Applications
```

之后双击 `twig.app` 就能用，跟别的 Mac 应用一样。这个 .app 只是个启动器：
双击后它把服务丢到后台、打开浏览器，自己就退出了，所以不会在 Dock 里占位，
也不会因为"关掉 App"而把服务杀掉。重复双击不会起第二个进程——只会把浏览器
带回到已经在跑的那个实例上。

**方式二：命令行**

```bash
go build -o ~/bin/twig .        # 需要 Go 1.25+
twig                            # 打开当前目录所在的仓库
twig /path/to/repo              # 打开指定仓库
twig -no-open                   # 不自动开浏览器
twig -new                       # 硬起一个新实例，不复用在跑的那个
```

它在本机起一个 HTTP 服务，用浏览器当界面。静态文件用 `go:embed` 打进了二进制，
所以拷贝一个文件到哪都能跑。

## 只会有一个实例

twig 的用法是**长期开着一个，在界面里切仓库**，不是每个仓库起一个进程。

在某个项目目录里敲 `twig`（或双击图标）时：

- 还没有实例在跑 → 起一个，打开这个仓库
- 已经有实例在跑 → **不起第二个**，让那个实例切到这个仓库，并把浏览器带到前台

想同时开两个窗口看两个仓库，用 `twig -new`。

端口默认固定在 **7890**（被占用才退让到随机端口），令牌也在 `~/.twig/` 里存着、
重启后不变，所以可以直接把 `http://127.0.0.1:7890/` 存成浏览器书签，
不用每次回终端复制带 token 的地址。

关掉服务：`Ctrl+C`（命令行启动的），或 `pkill -f twig`。

## 能做什么

**看历史**

- 提交图：分叉、合并、分支标签、tag、当前 HEAD，配色按分支链走
- **左侧勾选分支**：图上只画勾中的那几条（这是 SourceTree 没有的）
- **First parent only**（图区右下角）：只沿第一父提交走，合并进来的分支细节全折叠，只剩一条主线
- 分支过滤框、显示条数可调（200 / 500 / 1000 / 3000）
- 点提交看详情：改动文件列表 + 逐行 diff

**改东西**

- Working Copy：暂存 / 取消暂存 / 丢弃单个文件，提交（含 Amend 修补上一个提交）
- 分支：切换、新建、删除本地或远程分支、合并、变基
- 远端：Fetch、Pull、Push（首次推送自动建立上游关联）
- Stash：存、恢复（pop / apply）、删除
- Reset：soft / mixed / hard 三种模式
- 合并冲突时，顶栏会出现 Continue / Abort 按钮

右键点提交或分支，能做的事都在菜单里。

## 一些说明

**为什么勾了分支还看到别的分支的提交？**

因为那些提交已经合并进你勾选的分支了 —— 它们确实是这条分支历史的一部分，
`git log <分支>` 也会列出来。想只看这条分支自己的推进过程，勾上图区右下角的
**First parent only**。

**安全**

- 只监听 `127.0.0.1`，并校验请求的 Host，别的机器连不上
- 接口调用必须带令牌。令牌随机生成后存在 `~/.twig/instance.json`（权限 0600）、
  重启后复用（书签才不会失效）；页面从地址栏读一次就把它从 URL 里抹掉
- 分支名 / 提交号这类参数会直接交给 git，以 `-` 开头的一律拒绝，防止被当成命令行选项
- 推送用 `--force-with-lease` 而不是 `--force`：远端有别人的新提交时会拒绝，不会误覆盖

**这些东西存在哪**

`~/.twig/` 下面：

- `state.json` —— 最近打开的仓库、每个仓库上次勾了哪几条分支
- `instance.json` —— 正在跑的实例的端口和令牌（权限 0600）。它退出后不会自动删，
  留着是为了让令牌保持不变、书签一直有效；下次启动靠探活判断旧实例还在不在，
  不是只看这个文件在不在
- `twig.log` —— 双击 .app 启动时的输出（超过 1MB 自动清空）

## 代码结构

```
main.go                    启动、单实例判断、挑端口、开浏览器
packaging/
  make-app.sh              打包成 macOS 的 twig.app
  make-icon.py             画应用图标（纯标准库手写 PNG）
internal/instance/
  instance.go              "当前跑着的那个 twig"：端口 / 令牌记录与探活
internal/git/
  exec.go                  调 git 命令行的封装
  log.go                   读提交历史与分支 / tag
  graph.go                 提交图的轨道布局算法（核心）
  status.go                工作区状态
  diff.go                  diff 解析
  ops.go                   所有写操作（暂存 / 提交 / 切分支 / 推拉 / stash）
internal/server/
  server.go                路由、本机校验、令牌
  handlers.go              各接口
  state.go                 偏好持久化
web/                       界面：三个文件，没有构建步骤
  index.html  style.css  app.js
```

不用 libgit2 之类的绑定库，一律调 git 命令行 —— 行为和你在终端里敲的完全一致。

前端没有框架也没有打包工具，改完 `web/` 里的文件刷新页面就生效（改完记得重新
`go build` 才会进二进制）。代码注释用中文，界面文案用英文。

⚠️ 改完代码想让 `twig.app` 也用上新版本，要重新跑一次 `./packaging/make-app.sh -i`
——.app 里装的是打包那一刻的二进制副本。
