import Foundation

// 开发阶段用的文件日志：不管是 `open` 启动还是 Xcode 跑起来，都能在这个固定路径
// 看到输出，比 print() 依赖谁在盯着终端稳。正式发布前会删掉这个文件。
enum DebugLog {
    static let path = NSHomeDirectory() + "/.twig/mac-debug.log"

    static func write(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
        print(s)
    }
}
