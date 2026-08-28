import Foundation

// TwigClient 是 Go 后端所有 HTTP 接口的薄封装。
//
// 后端一个字节都没改——这层就是把 web/app.js 里 apiGet/apiPost 做的事换成 Swift。
// 所有接口都要带 X-Twig-Token 头，见 internal/server/server.go 的 guard。
final class TwigClient {
    let baseURL: URL
    let token: String
    private let session: URLSession

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let config = URLSessionConfiguration.default
        // 长轮询 /api/watch 会挂到 25 秒，普通请求不该被这个拖累，
        // 所以超时给宽一点，靠调用方（watch 循环）自己控制节奏。
        config.timeoutIntervalForRequest = 35
        self.session = URLSession(configuration: config)
    }

    enum ClientError: Error, LocalizedError {
        case http(status: Int, message: String)
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .http(_, let message): return message
            case .decode(let e): return "decode error: \(e)"
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        // path 形如 "/api/graph?limit=500"——调用方已经用 URLComponents 把 query
        // 编码好了，这里只是简单拼接。⚠️ 早先用 URL(string:relativeTo:) 再套一层
        // URLComponents(resolvingAgainstBaseURL:false) 去重建，结果丢了 scheme/host，
        // 每个请求都报 "unsupported URL"——resolvingAgainstBaseURL:false 是"按这个
        // URL 自己的原始表示取字段，不跟 base 合并"，而相对 URL 自己是没有 scheme 的。
        let baseStr = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let url = URL(string: baseStr + path) else {
            throw ClientError.http(status: -1, message: "bad URL: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Twig-Token")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.http(status: -1, message: "no HTTP response")
        }
        if http.statusCode >= 400 {
            // 失败响应体形如 {"error": "..."}（有的接口还带 output）。
            let message = (try? JSONDecoder().decode(OpError.self, from: data))?.error
                ?? String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ClientError.http(status: http.statusCode, message: message)
        }
        return data
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await request(path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ClientError.decode(error)
        }
    }

    // MARK: - 只读接口

    func ping() async throws -> Bool {
        let data = try await request("/api/ping")
        return (try? JSONDecoder().decode([String: String].self, from: data))?["app"] == "twig"
    }

    func bootstrap() async throws -> BootstrapResponse { try await get("/api/bootstrap") }
    func refs() async throws -> RefsResponse { try await get("/api/refs") }
    func status() async throws -> Status { try await get("/api/status") }
    func stashes() async throws -> [Stash] {
        struct Wrap: Decodable { let stashes: [Stash] }
        let w: Wrap = try await get("/api/stashes")
        return w.stashes
    }

    func browse(path: String) async throws -> [String] {
        struct Wrap: Decodable { let dirs: [String] }
        var comps = URLComponents(string: "/api/browse")!
        comps.queryItems = [URLQueryItem(name: "path", value: path)]
        let data = try await request(comps.string!)
        return (try? JSONDecoder().decode(Wrap.self, from: data))?.dirs ?? []
    }

    // refs 为 nil 表示画全部分支；对应界面上"逐条勾选分支"的核心差异点。
    func graph(refs: [String]?, limit: Int, firstParent: Bool) async throws -> Graph {
        var comps = URLComponents(string: "/api/graph")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if firstParent { items.append(URLQueryItem(name: "firstParent", value: "1")) }
        if let refs { items.append(URLQueryItem(name: "refs", value: refs.joined(separator: ","))) }
        comps.queryItems = items
        let data = try await request(comps.string!)
        struct Wrap: Decodable { let graph: Graph }
        return try JSONDecoder().decode(Wrap.self, from: data).graph
    }

    func commitDetail(hash: String, ignoreWhitespace: Bool, ignoreComments: Bool) async throws -> CommitDetail {
        var comps = URLComponents(string: "/api/commit")!
        comps.queryItems = wsIcItems(hash: hash, ws: ignoreWhitespace, ic: ignoreComments)
        return try await get(comps.string!)
    }

    func rangeDetail(from: String, to: String, ignoreWhitespace: Bool, ignoreComments: Bool) async throws -> RangeDetail {
        var comps = URLComponents(string: "/api/rangediff")!
        comps.queryItems = wsIcItems(from: from, to: to, ws: ignoreWhitespace, ic: ignoreComments)
        return try await get(comps.string!)
    }

    private func wsIcItems(hash: String? = nil, from: String? = nil, to: String? = nil, ws: Bool, ic: Bool) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let hash { items.append(.init(name: "hash", value: hash)) }
        if let from { items.append(.init(name: "from", value: from)) }
        if let to { items.append(.init(name: "to", value: to)) }
        if ws { items.append(.init(name: "ws", value: "1")) }
        if ic { items.append(.init(name: "ic", value: "1")) }
        return items
    }

    // patch 是三种视图共用的单文件 diff 取数接口，口径见 internal/server/handlers.go 的注释。
    func patch(_ req: DiffRequest) async throws -> PatchResponse {
        var comps = URLComponents(string: "/api/patch")!
        var items = [
            URLQueryItem(name: "mode", value: req.mode.rawValue),
            URLQueryItem(name: "path", value: req.path),
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
        return try await get(comps.string!)
    }

    // MARK: - 长轮询自动刷新

    // watch 挂到服务端真有变化、或最多 30 秒（比服务端自己的 25 秒超时略宽，
    // 给网络往返留余量）才返回。调用方在一个循环里反复调它，参见 AppState.watchLoop。
    func watch(since: UInt64) async throws -> UInt64 {
        var comps = URLComponents(string: "/api/watch")!
        comps.queryItems = [URLQueryItem(name: "since", value: String(since))]
        let data = try await request(comps.string!)
        return try JSONDecoder().decode(WatchResponse.self, from: data).version
    }

    // MARK: - 写操作

    func open(path: String) async throws -> RepoInfo {
        let body = try JSONEncoder().encode(["path": path])
        let data = try await request("/api/open", method: "POST", body: body)
        return try JSONDecoder().decode(RepoInfo.self, from: data)
    }

    func forget(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        _ = try await request("/api/forget", method: "POST", body: body)
    }

    @discardableResult
    func op(_ req: OpRequest) async throws -> String {
        let body = try JSONEncoder().encode(req)
        let data = try await request("/api/op", method: "POST", body: body)
        return try JSONDecoder().decode(OpResult.self, from: data).output
    }
}

// OpRequest 对应后端 internal/server/handlers.go 的 opRequest：所有写操作走同一个入口，
// 用 action 区分，其余字段按需要填、其它保持零值（后端会忽略用不到的字段）。
struct OpRequest: Encodable {
    var action: String
    var paths: [String] = []
    var untracked: [String] = []
    var message: String = ""
    var amend: Bool = false
    var stageAll: Bool = false
    var target: String = ""
    var name: String = ""
    var startPoint: String = ""
    var checkout: Bool = false
    var force: Bool = false
    var noFF: Bool = false
    var rebase: Bool = false
    var mode: String = ""
    var remote: String = ""
    var ref: String = ""
    var drop: Bool = false
    var state: String = ""
    var includeUntracked: Bool = false
}
