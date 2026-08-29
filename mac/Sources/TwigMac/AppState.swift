import Foundation
import AppKit

// 下方详情面板到底在看什么：某个提交、比较两个提交、还是工作区。
// 对应 web/app.js 里 S.selCommit / S.cmpB / S.wipMode 这三种互斥状态，
// 这里收成一个枚举，别处判断"当前在看哪种"时不会漏掉一种。
enum DetailMode: Equatable {
    case none
    case commit(hash: String)
    case compare(from: String, to: String)
    case workingCopy
}

// "Locate in graph" 的滚动请求：nonce 每次自增，
// 这样连续定位到同一行（值没变）时 onChange 也照样能触发。
struct GraphScrollRequest: Equatable {
    let hash: String
    let nonce: Int
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - 连接状态
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case failed(String)
    }
    @Published var connection: ConnectionState = .connecting
    private var client: TwigClient?

    // MARK: - 仓库 / 侧边栏
    @Published var repo: RepoInfo?
    @Published var recent: [String] = []
    @Published var refs: [Ref] = []
    @Published var head: HeadInfo?
    @Published var selectedRefs: Set<String> = []   // 空集合表示"全选"，跟后端 refs="" 的语义一致
    @Published var stashes: [Stash] = []
    @Published var status: Status?

    // MARK: - 提交图
    @Published var graph: Graph?
    @Published var firstParent = false { didSet { UserDefaults.standard.set(firstParent, forKey: "twig.firstParent") } }
    @Published var limit = 500 { didSet { UserDefaults.standard.set(limit, forKey: "twig.limit") } }

    // MARK: - 详情面板
    @Published var detailMode: DetailMode = .none { didSet { saveLastSelection() } }
    @Published var commitDetail: CommitDetail?
    @Published var rangeDetail: RangeDetail?
    @Published var selectedFile: DiffFile?
    // 图区滚动请求（Locate in graph / 点 tag 行时用），nil 表示没有请求。
    @Published var graphScrollRequest: GraphScrollRequest?
    private var graphScrollNonce = 0

    // 请求把某一行滚到图区中央；只负责发请求，真正的 scrollTo 在 GraphPane 里做。
    func requestGraphScroll(_ hash: String) {
        graphScrollNonce += 1
        graphScrollRequest = GraphScrollRequest(hash: hash, nonce: graphScrollNonce)
    }

    // MARK: - diff 面板
    //
    // ⚠️ diff 内容本身不再由 Swift 取——那条路交给内嵌的 WKWebView（DiffWebView）
    // 自己去调 /api/patch、自己交给 diff2html 画，原生这边只负责算出"该看哪个文件"
    // 并拼成一个 URL。这样 diff2html 那一整套（行内高亮/并排/语法着色/防误藏的六条
    // 注释正则）一份实现都不用抄第二遍到 Swift 里，将来 Go 那边 /api/patch 的口径
    // 变了，这边也不用跟着改。
    @Published var currentDiffRequest: DiffRequest?
    @Published var diffViewMode: DiffViewMode = .unified {
        didSet { UserDefaults.standard.set(diffViewMode == .split ? "split" : "unified", forKey: "twig.diffViewMode") }
    }

    // MARK: - diff 过滤开关（跟浏览器版同名同义）
    @Published var ignoreWhitespace = false { didSet { UserDefaults.standard.set(ignoreWhitespace, forKey: "twig.ignoreWhitespace") } }
    @Published var ignoreComments = false { didSet { UserDefaults.standard.set(ignoreComments, forKey: "twig.ignoreComments") } }

    @Published var busy = false
    @Published var lastError: String?

    // MARK: - 状态栏（对应 web 的 setStatus / lastOutput）
    //
    // 底部一条状态条，显示当前在干什么、上一条 git 命令的结果摘要。
    // kind: "" 普通 / "busy" 正在执行 / "err" 出错。点状态条弹出 lastOutput 的全文。
    @Published var statusMessage: String = ""
    @Published var statusKind: String = ""   // "" / "busy" / "err"
    @Published var lastOutput: (title: String, text: String)? = nil
    @Published var showOutputModal: Bool = false

    // MARK: - 自动刷新开关（对应 web 的 S.autoRefresh）
    //
    // 默认开。关掉之后 watchLoop 不再去问 /api/watch，服务端那边没人问也会把探测停掉。
    @Published var autoRefresh: Bool = true

    // 侧边栏显隐（菜单 View > Toggle Sidebar，⌥⌘S）。
    @Published var sidebarVisible: Bool = true { didSet { UserDefaults.standard.set(sidebarVisible, forKey: "twig.sidebarVisible") } }

    // MARK: - 偏好持久化（UserDefaults，不碰后端 state.json）
    //
    // 记住的都是界面偏好：开关、视图模式、每个仓库上次在看什么。重启后回到
    // 离开时的样子——这是 Mac 应用的默认行为，不是功能。读初值在 init，
    // 写回靠上面各属性的 didSet（init 里赋值不触发 didSet，不会先写一遍）。

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "twig.firstParent") != nil { firstParent = d.bool(forKey: "twig.firstParent") }
        if let l = d.object(forKey: "twig.limit") as? Int { limit = l }
        if let m = d.string(forKey: "twig.diffViewMode") { diffViewMode = m == "split" ? .split : .unified }
        ignoreWhitespace = d.bool(forKey: "twig.ignoreWhitespace")
        ignoreComments = d.bool(forKey: "twig.ignoreComments")
        if d.object(forKey: "twig.sidebarVisible") != nil { sidebarVisible = d.bool(forKey: "twig.sidebarVisible") }
    }

    // 每个仓库记住"上次在看什么"（提交 hash 或工作区），下次打开这个仓库时还原。
    private func saveLastSelection() {
        guard let path = repo?.path else { return }
        let v: String
        switch detailMode {
        case .commit(let h): v = h
        case .workingCopy: v = "workingCopy"
        default: v = ""
        }
        UserDefaults.standard.set(v, forKey: "twig.lastSel.\(path)")
    }

    // 还原上次在这个仓库看的东西；提交已不在当前图上（被筛掉或超出 limit）就放弃。
    private func restoreLastSelection() async {
        guard let path = repo?.path else { return }
        let last = UserDefaults.standard.string(forKey: "twig.lastSel.\(path)") ?? ""
        if last == "workingCopy" {
            if let st = status, !st.clean { await showWorkingCopy() }
        } else if !last.isEmpty,
                  graph?.commits.contains(where: { $0.hash == last }) == true {
            await selectCommit(last)
        }
    }

    // MARK: - 比较模式（Cmd/Ctrl 勾第二个提交）
    // 比较状态完全由 detailMode .compare(from:to:) 承载，不需要额外的 anchor 字段。

    private var watchVersion: UInt64 = 0
    private var watchTask: Task<Void, Never>?

    // diffPageURL 是要交给 DiffWebView 加载的完整地址：/diff.html + 全部参数。
    // token 直接放进 URL（diff.html 是静态资源，本来就不需要 token 才能加载；
    // 它自己发起的 /api/patch 请求会用这个 token 走 X-Twig-Token 头）。
    var diffPageURL: URL? {
        guard let req = currentDiffRequest, let client else { return nil }
        guard var comps = URLComponents(url: client.baseURL.appendingPathComponent("diff.html"), resolvingAgainstBaseURL: false) else { return nil }
        var items = [
            URLQueryItem(name: "token", value: client.token),
            URLQueryItem(name: "mode", value: req.mode.rawValue),
            URLQueryItem(name: "path", value: req.path),
            URLQueryItem(name: "view", value: diffViewMode == .split ? "split" : "unified"),
        ]
        if !req.orig.isEmpty { items.append(.init(name: "orig", value: req.orig)) }
        if req.ignoreWhitespace { items.append(.init(name: "ws", value: "1")) }
        if req.ignoreComments { items.append(.init(name: "ic", value: "1")) }
        switch req.mode {
        case .commit:
            items.append(.init(name: "hash", value: req.hash))
        case .range:
            items.append(.init(name: "from", value: req.from))
            items.append(.init(name: "to", value: req.to))
        case .work:
            items.append(.init(name: "staged", value: req.staged ? "1" : "0"))
            items.append(.init(name: "untracked", value: req.untracked ? "1" : "0"))
        }
        comps.queryItems = items
        return comps.url
    }

    // MARK: - 启动

    func connect() async {
        connection = .connecting
        do {
            let inst = try await BackendConnector.connect()
            DebugLog.write("[twig] 连上了 port=\(inst.port) token=\(inst.token.prefix(6))…")
            client = TwigClient(baseURL: URL(string: "http://127.0.0.1:\(inst.port)/")!, token: inst.token)
            connection = .connected
            await bootstrap()
            startWatchLoop()
        } catch {
            DebugLog.write("[twig] connect 失败: \(error)")
            connection = .failed(error.localizedDescription)
        }
    }

    func bootstrap() async {
        guard let client else { return }
        do {
            let boot = try await client.bootstrap()
            DebugLog.write("[twig] bootstrap 成功，repo=\(boot.repo?.name ?? "nil")，recent=\(boot.recent.count) 条")
            recent = boot.recent
            if let r = boot.repo {
                repo = r
                selectedRefs = Set(r.selectedRefs)
                await refreshAll()
                // 启动后还原上次在这个仓库看的东西（提交或工作区，存 UserDefaults）。
                // 不是默认进工作区——那会让侧边栏和图区两行同时高亮，看着像排版坏了；
                // 只还原用户自己离开时的选择。
                await restoreLastSelection()
            }
        } catch {
            DebugLog.write("[twig] bootstrap 出错: \(error)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - 刷新

    // 对应 web 的 refreshAll：重读 refs/graph/status/stashes，并重新加载当前详情面板
    // 展示的内容——外部改了仓库（自动刷新、手动 Refresh）都走这条路。
    func refreshAll() async {
        guard let client, repo != nil else { return }
        busy = true
        defer { busy = false }
        do {
            async let refsResp = client.refs()
            async let graphResp = client.graph(
                refs: selectedRefs.isEmpty ? nil : Array(selectedRefs),
                limit: limit, firstParent: firstParent)
            async let statusResp = client.status()
            async let stashResp = client.stashes()

            let r = try await refsResp
            refs = r.refs
            head = r.head
            // 服务端记住的勾选可能引用了已删除的分支，清理掉。
            let valid = Set(r.refs.map { $0.fullName })
            selectedRefs = selectedRefs.filter { valid.contains($0) }

            graph = try await graphResp
            status = try await statusResp
            stashes = try await stashResp

            await reloadCurrentDetail()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadGraphOnly() async {
        guard let client, repo != nil else { return }
        do {
            graph = try await client.graph(
                refs: selectedRefs.isEmpty ? nil : Array(selectedRefs),
                limit: limit, firstParent: firstParent)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadCurrentDetail() async {
        switch detailMode {
        case .commit(let hash): await selectCommit(hash, remember: false)
        case .compare(let from, let to): await loadCompare(from: from, to: to)
        case .workingCopy: await loadWorkingCopyFile()
        case .none: break
        }
    }

    // MARK: - 选提交 / 比较 / 工作区

    func selectCommit(_ hash: String, remember: Bool = true) async {
        guard let client else { return }
        if remember {
            detailMode = .commit(hash: hash)
        }
        do {
            DebugLog.write("[twig] selectCommit \(hash.prefix(8)) 开始")
            let d = try await client.commitDetail(hash: hash, ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments)
            DebugLog.write("[twig] selectCommit 成功，files=\(d.files.count)")
            commitDetail = d
            rangeDetail = nil
            // 保持原来选中的文件（如果还在新清单里），否则选第一个。
            if let cur = selectedFile, d.files.contains(where: { $0.path == cur.path }) {
                await selectFile(cur, inCommit: hash)
            } else if let first = d.files.first {
                await selectFile(first, inCommit: hash)
            } else {
                selectedFile = nil; currentDiffRequest = nil
            }
        } catch {
            DebugLog.write("[twig] selectCommit 出错: \(error)")
            lastError = error.localizedDescription
        }
    }

    // Cmd/Ctrl 点第二个提交 —— 比较两个版本。
    // 行为对齐 web 版 toggleCompare：
    //   - 普通模式（.commit）点另一条提交 → 进入比较模式，当前选中的当锚点
    //   - 普通模式点同一条 → 什么都不做
    //   - 不在 .commit（工作区/空态）→ 先选中这条，下一次 Cmd+点才进比较
    //   - 已在比较模式点端点 → 退出比较，回到锚点那条
    //   - 已在比较模式点其他提交 → 换"到"那一端，锚点不动
    func compareWith(_ hash: String) async {
        switch detailMode {
        case .commit(let anchor):
            if anchor == hash { return }  // 点同一条，什么都不做
            await loadCompare(from: anchor, to: hash)
        case .compare(let from, let to):
            if hash == from || hash == to {
                // 点端点 → 退出比较，选中锚点（from 那条）
                await selectCommit(from)
            } else {
                // 点其他提交 → 换"到"那一端
                await loadCompare(from: from, to: hash)
            }
        default:
            // 不在 commit 模式 → 先选中这条，下一次 Cmd+点才进比较
            await selectCommit(hash)
        }
    }

    func loadCompare(from: String, to: String) async {
        guard let client else { return }
        detailMode = .compare(from: from, to: to)
        do {
            let d = try await client.rangeDetail(from: from, to: to, ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments)
            rangeDetail = d
            commitDetail = nil
            if let cur = selectedFile, d.files.contains(where: { $0.path == cur.path }) {
                await selectFile(cur, inRange: (from, to))
            } else if let first = d.files.first {
                await selectFile(first, inRange: (from, to))
            } else {
                selectedFile = nil; currentDiffRequest = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func showWorkingCopy() async {
        detailMode = .workingCopy
        commitDetail = nil; rangeDetail = nil
        await loadWorkingCopyFile()
    }

    private func loadWorkingCopyFile() async {
        guard let st = status else { return }
        let all = st.staged + st.unstaged
        if let cur = selectedFile, let match = all.first(where: { $0.path == cur.path }) {
            await selectWorkingCopyFile(match)
        } else if let first = all.first {
            await selectWorkingCopyFile(first)
        } else {
            selectedFile = nil; currentDiffRequest = nil
        }
    }

    // MARK: - 选文件（三种模式殊途同归，最后都是发一次 /api/patch）

    // 三种模式殊途同归：都只是把参数拼成一个 DiffRequest，交给 WebView 自己去取。
    // 之所以不在这里直接 await 网络请求——WebView 里的 JS 会做同样的事，
    // Swift 这层再做一遍纯粹是重复劳动，还多一条"两边结果可能不一致"的路。
    func selectFile(_ f: DiffFile, inCommit hash: String) async {
        selectedFile = f
        currentDiffRequest = .init(mode: .commit, hash: hash, path: f.path, orig: f.origPath,
                                    ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments)
    }

    func selectFile(_ f: DiffFile, inRange range: (from: String, to: String)) async {
        selectedFile = f
        currentDiffRequest = .init(mode: .range, from: range.from, to: range.to, path: f.path, orig: f.origPath,
                                    ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments)
    }

    func selectWorkingCopyFile(_ f: FileChange) async {
        DebugLog.write("[twig] selectWorkingCopyFile \(f.path)")
        let df = DiffFile(path: f.path, origPath: f.origPath, status: "M")
        selectedFile = df
        currentDiffRequest = .init(mode: .work, path: f.path, orig: f.origPath,
                                    staged: f.staged, untracked: f.untracked,
                                    ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments)
    }

    // MARK: - 文件键盘导航（⌘↑/⌘↓，审 diff 手不离键盘）

    // 在当前详情模式的文件清单里把选中往前/往后挪一个，到顶/到底就停住（不循环）。
    func selectAdjacentFile(_ delta: Int) async {
        switch detailMode {
        case .commit(let h):
            guard let files = commitDetail?.files,
                  let path = adjacentPath(files.map { $0.path }, delta: delta),
                  let f = files.first(where: { $0.path == path }) else { return }
            await selectFile(f, inCommit: h)
        case .compare(let from, let to):
            guard let files = rangeDetail?.files,
                  let path = adjacentPath(files.map { $0.path }, delta: delta),
                  let f = files.first(where: { $0.path == path }) else { return }
            await selectFile(f, inRange: (from, to))
        case .workingCopy:
            guard let st = status else { return }
            // 顺序跟 WorkingCopyPane 的选中查找一致：staged → conflicts → unstaged。
            let all = st.staged + st.conflicts + st.unstaged
            guard let path = adjacentPath(all.map { $0.path }, delta: delta),
                  let f = all.first(where: { $0.path == path }) else { return }
            await selectWorkingCopyFile(f)
        case .none: break
        }
    }

    private func adjacentPath(_ paths: [String], delta: Int) -> String? {
        guard !paths.isEmpty else { return nil }
        let i = paths.firstIndex(of: selectedFile?.path ?? "") ?? (delta > 0 ? -1 : paths.count)
        let j = i + delta
        guard j >= 0, j < paths.count else { return nil }
        return paths[j]
    }

    // MARK: - 文件系统动作（工作区/详情文件行的右键菜单用）

    func fileURL(_ relativePath: String) -> URL? {
        repo.map { URL(fileURLWithPath: $0.path).appendingPathComponent(relativePath) }
    }

    func revealInFinder(_ relativePath: String) {
        guard let u = fileURL(relativePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([u])
    }

    func openFile(_ relativePath: String) {
        guard let u = fileURL(relativePath) else { return }
        NSWorkspace.shared.open(u)
    }

    func copyFilePath(_ relativePath: String) {
        if let u = fileURL(relativePath) { copyToClipboard(u.path) }
    }

    // MARK: - 分支勾选 / 视图选项

    // 当前分支（本地分支里 isHead 那条），工具栏 Pull/Push 的 ahead/behind 角标用。
    var currentBranchRef: Ref? { refs.first { $0.kind == "head" && $0.isHead } }

    // 只显示某一条分支（点提交行徽章用；效果等同侧边栏右键 "Show only this in graph"）。
    func showOnlyRef(_ fullName: String) {
        selectedRefs = [fullName]
        Task { await reloadGraphOnly() }
    }

    // 清除分支筛选，恢复"画全部"。
    func clearRefFilter() {
        selectedRefs = []
        Task { await reloadGraphOnly() }
    }

    // 当前筛选的分支短名（图工具条筛选 chip 显示用），refs 里找不到的用 fullName 兜底。
    var selectedRefNames: [String] {
        selectedRefs.map { full in refs.first(where: { $0.fullName == full })?.name ?? full }.sorted()
    }

    func toggleRef(_ fullName: String) {
        if selectedRefs.contains(fullName) { selectedRefs.remove(fullName) }
        else { selectedRefs.insert(fullName) }
        Task { await reloadGraphOnly() }
    }

    func setFirstParent(_ v: Bool) {
        firstParent = v
        Task { await reloadGraphOnly() }
    }

    func setAutoRefresh(_ v: Bool) {
        autoRefresh = v
    }

    func setIgnoreWhitespace(_ v: Bool) {
        ignoreWhitespace = v
        Task { await reloadCurrentDetail() }
    }

    func setIgnoreComments(_ v: Bool) {
        ignoreComments = v
        Task { await reloadCurrentDetail() }
    }

    // MARK: - 状态栏辅助

    func setStatus(_ msg: String, kind: String = "") {
        statusMessage = msg
        statusKind = kind
    }

    // MARK: - 确认弹窗（macOS 原生 NSAlert，比 SwiftUI .alert 更适合嵌套在 contextMenu 回调里）

    @discardableResult
    func confirm(title: String, message: String, buttonTitle: String = "OK",
                 destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        if destructive { alert.alertStyle = .warning }
        return alert.runModal() == .alertFirstButtonReturn
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        setStatus("Copied: \(text.prefix(60))")
    }

    // 输入弹窗：NSAlert + NSTextField，可选一个复选框。对应 web 的 askInput。
    // 用于新建分支（带"创建后切换"复选框）、stash（带"包含未跟踪文件"复选框）等。
    func askInput(title: String, message: String, placeholder: String = "",
                  checkboxLabel: String? = nil, checkboxChecked: Bool = false) -> (value: String, checked: Bool)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(string: "")
        input.placeholderString = placeholder
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)

        var checkbox: NSButton?
        if let label = checkboxLabel {
            checkbox = NSButton(checkboxWithTitle: label, target: nil, action: nil)
            checkbox?.state = checkboxChecked ? .on : .off
            let stack = NSStackView(views: [input, checkbox!])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = input
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value: value, checked: checkbox?.state == .on)
    }

    // MARK: - 写操作

    // runOp 是所有写操作的统一出口：调接口 → 出错就把原始输出存进 lastOutput + 状态条标红 →
    // 成功就刷新。成功时不弹窗，状态条给一句摘要，想看全文点状态条。
    @discardableResult
    func runOp(_ req: OpRequest, label: String) async -> Bool {
        guard let client else { return false }
        busy = true
        setStatus("\(label)…", kind: "busy")
        defer { busy = false }
        do {
            let res = try await client.op(req)
            await refreshAll()
            let out = res.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty {
                lastOutput = (title: label, text: out)
                let tail = out.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
                setStatus("\(label) done\(tail.isEmpty ? "" : " · \(tail)")  (click for full output)")
            } else {
                setStatus("\(label) done")
            }
            return true
        } catch {
            let text = "\(error.localizedDescription)"
            lastOutput = (title: "\(label) failed", text: text)
            setStatus("\(label) failed: \(error.localizedDescription)", kind: "err")
            await refreshAll()
            return false
        }
    }

    // 换仓库入口：网页版是自己实现的文件夹浏览弹窗（走 /api/browse），原生这边
    // 直接用系统的 NSOpenPanel——不用把那套浏览逻辑再抄一遍，用户也更熟悉。
    // 选完调的还是同一个 /api/open，跟 openRepo(_:) 走一套路径。
    func openRepoPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if let current = repo?.path {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openRepo(url.path) }
    }

    func openRepo(_ path: String) async {
        guard let client else { return }
        do {
            let info = try await client.open(path: path)
            repo = info
            selectedRefs = Set(info.selectedRefs)
            // ⚠️ 换仓库瞬间必须把旧仓库的所有展示数据清掉。refreshAll() 是网络请求，
            // 返回前界面会用还挂在 @Published 上的旧数据渲染——结果就是"工具栏写着
            // 新仓库名、图区却是旧仓库的提交图"。跟网页版 2026-08-28 修的那个
            // "换仓库时旧内容画到新界面上"是同一个 bug，这里别只清 detailMode。
            detailMode = .none
            selectedFile = nil
            commitDetail = nil
            rangeDetail = nil
            currentDiffRequest = nil
            graph = nil
            refs = []
            head = nil
            stashes = []
            status = nil
            await refreshAll()
            // 后端 /api/open 会把这次打开的仓库记进它自己的"最近"列表（排到最前面），
            // 但 Swift 这边的 recent 只在启动那次 bootstrap() 时取过一次快照，换仓库
            // 之后不重新拉的话，侧边栏"Recent"顺序就跟后端记的对不上——新打开的这个
            // 不会立刻跳到最前面，得等下次重启 app 才刷新。这里顺手拉一次最新的。
            if let boot = try? await client.bootstrap() { recent = boot.recent }
            // 换仓库后还原那个仓库上次的选择（同 bootstrap()）。
            await restoreLastSelection()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - 自动刷新（长轮询，跟浏览器版共用同一个 /api/watch）

    private func startWatchLoop() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let client = self.client else { return }
                // 开关关了就不去问，服务端那边没人问也会把探测停掉（对应 web 坑 K 的另一半）。
                if !self.autoRefresh { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }
                do {
                    let v = try await client.watch(since: self.watchVersion)
                    if v != self.watchVersion {
                        self.watchVersion = v
                        await self.refreshAll()
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    // MARK: - 常用操作快捷方法（封装确认弹窗 + 特殊参数逻辑）

    // 新建分支的完整交互（输入弹窗 + 创建 + 可选切换）。
    // 工具栏按钮、Repository 菜单、侧边栏 + 三个入口共用这一套。
    func newBranchPrompt() {
        if let r = askInput(title: "New Branch", message: "Starting from the current HEAD",
                             placeholder: "feature/my-branch",
                             checkboxLabel: "Check out after creating", checkboxChecked: true) {
            Task { await runOp(.init(action: "createBranch", name: r.value,
                                      startPoint: "HEAD", checkout: r.checked),
                                label: "Create branch \(r.value)") }
        }
    }

    // Stash 当前改动的完整交互（工作区干净时直接提示，不弹窗）。
    func stashPrompt() {
        if status?.clean ?? true {
            setStatus("Working copy is clean — nothing to stash", kind: "err")
            return
        }
        if let r = askInput(title: "Stash Changes",
                             message: "Put the current uncommitted changes aside.",
                             placeholder: "Message (optional)",
                             checkboxLabel: "Include untracked files", checkboxChecked: true) {
            Task { await runOp(.init(action: "stashPush", message: r.value,
                                      includeUntracked: r.checked), label: "Stash") }
        }
    }

    // checkout：远程分支会创建本地跟踪分支，tag 会警告 detached HEAD，本地分支直接切。
    func checkoutRef(_ ref: Ref) async {
        if ref.kind == "remote" {
            await runOp(.init(action: "checkoutRemote", target: ref.name), label: "Create local branch from \(ref.name)")
        } else if ref.kind == "tag" {
            guard confirm(title: "Checkout tag \(ref.name)",
                          message: "Checking out a tag will leave you on a detached HEAD.",
                          buttonTitle: "Checkout") else { return }
            await runOp(.init(action: "checkout", target: ref.name), label: "Checkout \(ref.name)")
        } else {
            await runOp(.init(action: "checkout", target: ref.name), label: "Checkout \(ref.name)")
        }
    }

    func checkoutCommit(_ hash: String) async {
        await runOp(.init(action: "checkout", target: hash), label: "Checkout \(String(hash.prefix(8)))")
    }

    func discardFile(_ path: String, untracked: Bool) async {
        guard confirm(title: "Discard changes",
                      message: "Discard changes to \(path)?\nThis cannot be undone.",
                      buttonTitle: "Discard", destructive: true) else { return }
        if untracked {
            await runOp(.init(action: "discard", untracked: [path]), label: "Discard \(path)")
        } else {
            await runOp(.init(action: "discard", paths: [path]), label: "Discard \(path)")
        }
    }

    func hardReset(to hash: String) async {
        guard confirm(title: "Hard reset",
                      message: "Hard-reset the current branch to \(String(hash.prefix(8)))?\nAll uncommitted changes will be lost. This cannot be undone.",
                      buttonTitle: "Hard Reset", destructive: true) else { return }
        await runOp(.init(action: "reset", target: hash, mode: "hard"), label: "Hard reset to \(String(hash.prefix(8)))")
    }

    func deleteBranch(_ name: String) async {
        let ok = await runOp(.init(action: "deleteBranch", name: name), label: "Delete \(name)")
        if !ok {
            if confirm(title: "Delete branch \(name)",
                       message: "\(name) is not fully merged. Force delete?",
                       buttonTitle: "Force Delete", destructive: true) {
                await runOp(.init(action: "deleteBranch", name: name, force: true), label: "Force delete \(name)")
            }
        }
    }

    func deleteRemoteBranch(_ name: String) async {
        guard confirm(title: "Delete remote branch \(name)",
                      message: "This affects everyone on the remote.",
                      buttonTitle: "Delete", destructive: true) else { return }
        await runOp(.init(action: "deleteRemoteBranch", name: name), label: "Delete remote \(name)")
    }

    // 从"最近"列表里摘掉一条仓库（对应 web 的 /api/forget + renderRecent）。
    func forgetRepo(_ path: String) async {
        guard let client else { return }
        do {
            try await client.forget(path: path)
            if let boot = try? await client.bootstrap() { recent = boot.recent }
        } catch {
            setStatus("Failed to remove from recent: \(error.localizedDescription)", kind: "err")
        }
    }

    // 拿 HEAD 提交的完整信息（subject + body），用于 amend 时自动填充输入框。
    func lastCommitMessage() async -> String? {
        guard let client, let head = head?.hash else { return nil }
        do {
            let d = try await client.commitDetail(hash: head, ignoreWhitespace: false, ignoreComments: false)
            return d.body.isEmpty ? d.subject : "\(d.subject)\n\n\(d.body)"
        } catch {
            return nil
        }
    }

    deinit { watchTask?.cancel() }
}
