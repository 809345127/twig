import Foundation

// 这些类型是 Go 后端 JSON 响应的原样映射（字段名、大小写都对齐 internal/git 与
// internal/server 里的 struct）。改后端字段时这里要跟着改，两边靠 JSON 字符串对话，
// 编译期完全查不出字段名对不上——所以每加一个字段都去 Go 源码里核一遍原名。

struct Commit: Codable, Identifiable, Hashable {
    var id: String { hash }
    let hash: String
    let short: String
    let parents: [String]
    let authorName: String
    let authorMail: String
    let timestamp: Int64
    let subject: String
    var row: Int = 0
    var lane: Int = 0
    var refs: [Ref] = []
}

struct Ref: Codable, Hashable {
    let kind: String   // "head" / "remote" / "tag"
    let name: String
    let fullName: String
    let hash: String
    let upstream: String
    let ahead: Int
    let behind: Int
    let isHead: Bool
}

struct HeadInfo: Codable, Hashable {
    let branch: String
    let hash: String
    let detached: Bool
}

struct Edge: Codable {
    let fromRow: Int
    let fromLane: Int
    let toRow: Int
    let toLane: Int
    let lane: Int
    let color: Int
    let merge: Bool
}

struct Graph: Codable {
    let commits: [Commit]
    let edges: [Edge]
    let width: Int
}

struct FileChange: Codable, Identifiable, Hashable {
    var id: String { path + "\u{0}" + origPath }
    let path: String
    var origPath: String = ""
    let index: String
    let work: String
    let staged: Bool
    let unstaged: Bool
    let untracked: Bool
    let conflict: Bool

    // ⚠️ Go 那边这个字段是 `json:"origPath,omitempty"`——值为空时整个键都不出现在
    // JSON 里，不是"值是空字符串"。属性写默认值只在手写代码时管用，对自动生成的
    // Decodable 没有任何效力：真按同名字段自动解码，缺键就直接抛 keyNotFound。
    // 所以但凡后端某个字段带 omitempty，Swift 这边就必须手写 init(from:) 兜底。
    enum CodingKeys: String, CodingKey {
        case path, origPath, index, work, staged, unstaged, untracked, conflict
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        origPath = try c.decodeIfPresent(String.self, forKey: .origPath) ?? ""
        index = try c.decode(String.self, forKey: .index)
        work = try c.decode(String.self, forKey: .work)
        staged = try c.decode(Bool.self, forKey: .staged)
        unstaged = try c.decode(Bool.self, forKey: .unstaged)
        untracked = try c.decode(Bool.self, forKey: .untracked)
        conflict = try c.decode(Bool.self, forKey: .conflict)
    }
    init(path: String, origPath: String = "", index: String, work: String, staged: Bool, unstaged: Bool, untracked: Bool, conflict: Bool) {
        self.path = path; self.origPath = origPath; self.index = index; self.work = work
        self.staged = staged; self.unstaged = unstaged; self.untracked = untracked; self.conflict = conflict
    }
}

struct Status: Codable {
    let staged: [FileChange]
    let unstaged: [FileChange]
    let conflicts: [FileChange]
    let clean: Bool
    let state: String
}

struct DiffFile: Codable, Identifiable, Hashable {
    var id: String { path + "\u{0}" + origPath }
    let path: String
    var origPath: String = ""
    let status: String   // A / M / D / R / C
    var additions: Int = 0
    var deletions: Int = 0
    var binary: Bool = false

    // 同 FileChange：origPath 在 Go 那边是 omitempty，必须手写 init(from:) 兜底缺键。
    enum CodingKeys: String, CodingKey {
        case path, origPath, status, additions, deletions, binary
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        origPath = try c.decodeIfPresent(String.self, forKey: .origPath) ?? ""
        status = try c.decode(String.self, forKey: .status)
        additions = try c.decodeIfPresent(Int.self, forKey: .additions) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        binary = try c.decodeIfPresent(Bool.self, forKey: .binary) ?? false
    }
    init(path: String, origPath: String = "", status: String, additions: Int = 0, deletions: Int = 0, binary: Bool = false) {
        self.path = path; self.origPath = origPath; self.status = status
        self.additions = additions; self.deletions = deletions; self.binary = binary
    }
}

struct CommitDetail: Codable {
    // Go 的 CommitDetail 是 struct { Commit; Body; CommitDate; Files }（内嵌），
    // JSON 编码出来是把 Commit 的字段拍平到同一层，所以这边手写 Codable 而不是内嵌。
    let hash: String
    let short: String
    let parents: [String]
    let authorName: String
    let authorMail: String
    let timestamp: Int64
    let subject: String
    let body: String
    let commitDate: Int64
    let files: [DiffFile]
}

struct RangeDetail: Codable {
    let from: Commit?
    let to: Commit?
    let files: [DiffFile]
    let ahead: Int
    let behind: Int
}

struct Stash: Codable, Identifiable, Hashable {
    var id: String { ref }
    let ref: String
    let subject: String
    let time: Int64
}

struct RepoInfo: Codable {
    let path: String
    let name: String
    let head: HeadInfo
    let remotes: [String]
    let selectedRefs: [String]
}

struct BootstrapResponse: Codable {
    let recent: [String]
    let home: String
    let repo: RepoInfo?
}

struct RefsResponse: Codable {
    let refs: [Ref]
    let head: HeadInfo
    let selected: [String]
}

struct GraphResponse: Codable {
    let graph: Graph
}

struct PatchResponse: Codable {
    let patch: String
    let truncated: Bool
}

struct OpResult: Codable {
    let output: String
}

struct OpError: Codable {
    let error: String
    let output: String?
}

struct WatchResponse: Codable {
    let version: UInt64
}

// PatchMode 对应 /api/patch 的 mode 参数。
enum PatchMode: String {
    case commit, range, work
}

// DiffViewMode 对应 diff.html 的 view 参数：unified 上下堆叠 / split 左右并排。
enum DiffViewMode {
    case unified, split
}

// 一次要取哪个文件的 diff：三种模式共用一套参数，跟后端 /api/patch 的口径一致。
struct DiffRequest: Equatable {
    var mode: PatchMode
    var hash: String = ""
    var from: String = ""
    var to: String = ""
    var path: String
    var orig: String = ""
    var staged: Bool = false
    var untracked: Bool = false
    var ignoreWhitespace: Bool = false
    var ignoreComments: Bool = false
}
