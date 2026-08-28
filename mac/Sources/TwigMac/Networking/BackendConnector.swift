import Foundation

// BackendConnector 找到（或拉起）那个跑着的 twig Go 后端，跟浏览器版走的是同一个实例。
//
// 这是"混合方案"的核心：Go 后端一个字节都不用改，原生窗口只是换了个方式接到
// 同一套 HTTP 接口上。复用同一个实例意味着：最近仓库列表、分支勾选偏好、
// 已经打开的仓库，原生窗口打开就直接是浏览器里那份状态，不用重新配一遍。
enum BackendConnector {
    struct Instance {
        let port: Int
        let token: String
    }

    struct ConnectError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // instance.json 跟 Go 那边 internal/instance/info.go 是同一份文件、同一套字段名。
    private struct InstanceFile: Decodable {
        let port: Int
        let token: String
        let pid: Int
    }

    private static var instancePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".twig/instance.json")
    }

    // connect 按这个顺序尝试：
    //   1. 读 ~/.twig/instance.json，探活——跟浏览器版共用的那个主实例多半就在这。
    //   2. 探活失败（没跑 / 是条过期记录）就自己拉起 twig 二进制，解析它打印的地址。
    static func connect() async throws -> Instance {
        if let info = try? Data(contentsOf: instancePath),
           let parsed = try? JSONDecoder().decode(InstanceFile.self, from: info),
           await ping(port: parsed.port, token: parsed.token) {
            return Instance(port: parsed.port, token: parsed.token)
        }
        return try await launch()
    }

    private static func ping(port: Int, token: String) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/ping") else { return false }
        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "X-Twig-Token")
        req.timeoutInterval = 1.5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONDecoder().decode([String: String].self, from: data)
        else { return false }
        return obj["app"] == "twig"
    }

    // 找 twig 二进制：先找 PATH 里的（go install . 装的那份），
    // 再退到 GOPATH/bin，找不到就报错，让用户自己先编译。
    private static func findBinary() -> String? {
        let candidates = [
            "/usr/local/bin/twig",
            NSHomeDirectory() + "/go/bin/twig",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // PATH 里搜一遍。
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let p = "\(dir)/twig"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    // 拉起一个新的 twig 后端（-no-open：原生窗口自己就是界面，不需要它再开浏览器）。
    //
    // twig 把地址打在 stdout 的第一行：
    //   twig is running: http://127.0.0.1:PORT/?token=TOKEN
    // 这跟坑 19 描述的"副实例不写 instance.json，只能从 stdout 拿 token"是同一件事——
    // 只是这里不是 -new 副实例，是"发现没人在跑"时启动的那个主实例，会正常写文件。
    private static func launch() async throws -> Instance {
        guard let bin = findBinary() else {
            throw ConnectError(message: "找不到 twig 二进制。先在仓库里跑一次 `go install .`（装到 ~/go/bin），再重开这个 App。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["-no-open"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // 不关心 stderr，但不重定向的话默认继承本进程的，会话里会很吵
        try process.run()

        let handle = pipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(5)
        var buffer = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { try? await Task.sleep(nanoseconds: 100_000_000); continue }
            buffer.append(chunk)
            if let text = String(data: buffer, encoding: .utf8),
               let line = text.split(separator: "\n").first,
               let parsed = parseStartupLine(String(line)) {
                return parsed
            }
        }
        throw ConnectError(message: "twig 后端启动超时（5 秒内没有打印地址）。")
    }

    // 解析 "twig is running: http://127.0.0.1:7890/?token=abc123"
    private static func parseStartupLine(_ line: String) -> Instance? {
        guard let range = line.range(of: "http://") else { return nil }
        guard let url = URL(string: String(line[range.lowerBound...])),
              let port = url.port,
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "token" })?.value
        else { return nil }
        return Instance(port: port, token: token)
    }
}
