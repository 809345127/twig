#!/bin/bash
# 造一个用来验 twig 的演示仓库。
#
# 为什么需要它：验证提交图这类功能，需要一个"形状足够复杂"的仓库——
# 有分叉、有两处合并、有 tag、有远端、有领先/落后、有各种未提交改动。
# 拿真实项目验有两个问题：慢，而且不敢在上面做写操作（提交 / reset / 删分支）。
#
# 用法：
#   ./testdata/make-demo-repo.sh [目标目录]     # 默认 /tmp/twig-demo
#
# 造完会打印出 twig 的启动命令。
set -euo pipefail

DEST="${1:-/tmp/twig-demo}"
REPO="$DEST/demo-repo"
REMOTE="$DEST/demo-repo-remote.git"
EMPTY="$DEST/empty-repo"

rm -rf "$DEST"; mkdir -p "$DEST"

# —— 主演示仓库 ——
mkdir -p "$REPO"; cd "$REPO"
git init -q -b main
git config user.name "Alice"; git config user.email a@example.com

# mk <文件> <内容> <日期> <提交信息>
mk() {
  echo "$2" >> "$1"
  git add "$1"
  GIT_AUTHOR_DATE="$3" GIT_COMMITTER_DATE="$3" git commit -q -m "$4"
}

mk README.md "hello"           "2026-08-01T10:00:00" "初始提交"
mk main.go   "package main"    "2026-08-01T11:00:00" "Add entry point"
mk main.go   "func main() {}"  "2026-08-02T09:00:00" "补上 main 函数"

# 一条 feature 分支，后面会被合并回来
git checkout -q -b feature/login
git config user.name "Bob"; git config user.email b@example.com
mk login.go "package auth"     "2026-08-02T14:00:00" "登录模块骨架"
mk login.go "func Login() {}"  "2026-08-03T10:00:00" "Implement login flow"

git checkout -q main
git config user.name "Alice"; git config user.email a@example.com
mk util.go "package util"      "2026-08-03T11:00:00" "加工具函数"

# 一条始终不合并的分支，用来验"只勾这条时图上是什么"
git checkout -q -b feature/payment
git config user.name "Carol"; git config user.email c@example.com
mk pay.go "package pay"        "2026-08-03T15:00:00" "支付模块"
mk pay.go "func Charge() {}"   "2026-08-04T09:00:00" "Add charge API"
mk pay.go "// refund"          "2026-08-04T16:00:00" "退款接口"

# 第一处合并
git checkout -q main
git config user.name "Alice"; git config user.email a@example.com
GIT_AUTHOR_DATE="2026-08-05T10:00:00" GIT_COMMITTER_DATE="2026-08-05T10:00:00" \
  git merge -q --no-ff feature/login -m "合并 feature/login"
mk README.md "docs"            "2026-08-05T14:00:00" "更新文档"

# 第二处合并 + 一个带注释的 tag
git checkout -q -b hotfix/crash
mk main.go "// fix crash"      "2026-08-06T09:00:00" "修复启动崩溃"
git checkout -q main
GIT_AUTHOR_DATE="2026-08-06T11:00:00" GIT_COMMITTER_DATE="2026-08-06T11:00:00" \
  git merge -q --no-ff hotfix/crash -m "合并 hotfix/crash"
git tag -a v1.0.0 -m "第一个正式版"
mk CHANGELOG.md "v1.0.0"       "2026-08-07T10:00:00" "写 changelog"

# 一条更新的 release 分支，让图上有并行的头
git checkout -q -b release/1.1
mk main.go "// v1.1"           "2026-08-08T10:00:00" "准备 1.1"
git checkout -q main

# —— 远端（bare 仓库，可以安全地 push / fetch / 删远程分支）——
git init -q --bare "$REMOTE"
git remote add origin "$REMOTE"
git push -q origin main feature/payment release/1.1 --tags 2>/dev/null
git branch --set-upstream-to=origin/main main >/dev/null 2>&1

# 本地领先远端一个提交 → 工具栏 Push 上会显示 ↑1
mk notes.md "local only"       "2026-08-09T10:00:00" "本地未推送的提交"

# —— 各种未提交改动 ——
echo "dirty" >> README.md                    # 已跟踪文件被改
echo "new file" > scratch.txt                # 未跟踪的新文件
echo "staged change" >> util.go && git add util.go   # 已暂存

# —— 一个全新的空仓库（验"还没有任何提交"这条路径）——
mkdir -p "$EMPTY"; cd "$EMPTY"
git init -q -b main
git config user.name "Tester"; git config user.email t@example.com

cat <<INFO

演示仓库已就绪：

  主仓库    $REPO
            5 条本地分支、2 处合并、1 个 tag、领先远端 1 个提交
            未提交改动：1 个已暂存 + 1 个已改 + 1 个未跟踪
  远端      $REMOTE   （bare，可以随便 push / 删分支）
  空仓库    $EMPTY    （验空仓库路径）

启动 twig 看它：

  twig -new -port 7899 "$REPO"

（用 -new 和另一个端口，免得干扰你正在用的那个 twig 实例）
INFO
