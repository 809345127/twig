import Foundation

// 下方详情面板到底在看什么：某个提交、比较两个提交、还是工作区。
// 对应 web/app.js 里 S.selCommit / S.cmpB / S.wipMode 这三种互斥状态，
// 这里收成一个枚举，别处判断"当前在看哪种"时不会漏掉一种。
enum DetailMode: Equatable {
    case none
    case commit(hash: String)
    case compare(from: String, to: String)
    case workingCopy
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
    @Published var firstParent = false
    @Published var limit = 500

    // MARK: - 详情面板
    @Published var detailMode: DetailMode = .none
    @Published var commitDetail: CommitDetail?
    @Published var rangeDetail: RangeDetail?
    @Published var selectedFile: DiffFile?
    @Published var diffPatch: String = ""
    @Published var diffTruncated = false
    @Published var diffError: String?

    // MARK: - diff 过滤开关（跟浏览器版同名同义）
    @Published var ignoreWhitespace = false
    @Published var ignoreComments = false

    @Published var busy = false
    @Published var lastError: String?

    // MARK: - 比较模式（Cmd/Ctrl 勾第二个提交）
    @Published var compareAnchor: String?   // 第一个选中的提交

    private var watchVersion: UInt64 = 0
    private var watchTask: Task<Void, Never>?
    private var diffLoadSeq = 0   // 防串号：连着点几个文件，只认最后一次的结果

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
                if let st = status, !st.clean {
                    detailMode = .workingCopy
                } else if let first = graph?.commits.first {
                    await selectCommit(first.hash)
                }
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
            compareAnchor = nil
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
                selectedFile = nil; diffPatch = ""
            }
        } catch {
            DebugLog.write("[twig] selectCommit 出错: \(error)")
            lastError = error.localizedDescription
        }
    }

    // Cmd/Ctrl 点第二个提交 —— 比较两个版本。
    func compareWith(_ hash: String) async {
        guard case .commit(let anchor) = detailMode, anchor != hash else {
            compareAnchor = hash
            return
        }
        await loadCompare(from: anchor, to: hash)
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
                selectedFile = nil; diffPatch = ""
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
            selectedFile = nil; diffPatch = ""
        }
    }

    // MARK: - 选文件（三种模式殊途同归，最后都是发一次 /api/patch）

    func selectFile(_ f: DiffFile, inCommit hash: String) async {
        selectedFile = f
        await loadPatch(.init(mode: .commit, hash: hash, path: f.path, orig: f.origPath,
                               ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments))
    }

    func selectFile(_ f: DiffFile, inRange range: (from: String, to: String)) async {
        selectedFile = f
        await loadPatch(.init(mode: .range, from: range.from, to: range.to, path: f.path, orig: f.origPath,
                               ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments))
    }

    func selectWorkingCopyFile(_ f: FileChange) async {
        let df = DiffFile(path: f.path, origPath: f.origPath, status: f.staged ? "M" : "M")
        selectedFile = df
        await loadPatch(.init(mode: .work, path: f.path, orig: f.origPath,
                               staged: f.staged, untracked: f.untracked,
                               ignoreWhitespace: ignoreWhitespace, ignoreComments: ignoreComments))
    }

    private func loadPatch(_ req: DiffRequest) async {
        guard let client else { return }
        diffLoadSeq += 1
        let seq = diffLoadSeq
        diffError = nil
        do {
            let resp = try await client.patch(req)
            guard seq == diffLoadSeq else { return }   // 串号防护：只认最后一次
            diffPatch = resp.patch
            diffTruncated = resp.truncated
        } catch {
            guard seq == diffLoadSeq else { return }
            diffPatch = ""
            diffError = error.localizedDescription
        }
    }

    // MARK: - 分支勾选 / 视图选项

    func toggleRef(_ fullName: String) {
        if selectedRefs.contains(fullName) { selectedRefs.remove(fullName) }
        else { selectedRefs.insert(fullName) }
        Task { await reloadGraphOnly() }
    }

    func setFirstParent(_ v: Bool) {
        firstParent = v
        Task { await reloadGraphOnly() }
    }

    func setIgnoreWhitespace(_ v: Bool) {
        ignoreWhitespace = v
        Task { await reloadCurrentDetail() }
    }

    func setIgnoreComments(_ v: Bool) {
        ignoreComments = v
        Task { await reloadCurrentDetail() }
    }

    // MARK: - 写操作

    @discardableResult
    func runOp(_ req: OpRequest) async -> Bool {
        guard let client else { return false }
        busy = true
        defer { busy = false }
        do {
            _ = try await client.op(req)
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func openRepo(_ path: String) async {
        guard let client else { return }
        do {
            let info = try await client.open(path: path)
            repo = info
            selectedRefs = Set(info.selectedRefs)
            detailMode = .none
            selectedFile = nil
            compareAnchor = nil
            await refreshAll()
            if let st = status, !st.clean { detailMode = .workingCopy }
            else if let first = graph?.commits.first { await selectCommit(first.hash) }
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

    deinit { watchTask?.cancel() }
}
