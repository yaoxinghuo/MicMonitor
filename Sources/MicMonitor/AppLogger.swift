import Foundation
import os

/// 日志:os.Logger(可通过 Console.app 检索)+ 文件 ~/Library/Logs/MicMonitor/app.log。
/// 文件超过 ~1MB 轮转为 app.log.1(只保留一份旧文件)。
/// 最近若干行缓存在内存里,供"复制诊断信息"带走。
/// 注意:实时音频线程不要调用 log() —— 它走串行队列 + 文件 IO。
final class AppLogger {
    static let shared = AppLogger()

    let directoryURL: URL
    let fileURL: URL

    private let osLogger: Logger
    private let queue = DispatchQueue(label: "micmonitor.logger", qos: .utility)
    private var handle: FileHandle?
    private var tail: [String] = []
    private let maxTailLines = 120
    private let maxFileSize = 1_000_000
    private let tsFormatter = ISO8601DateFormatter()

    private init() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.example.micmonitor"
        osLogger = Logger(subsystem: bundleID, category: "app")
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        directoryURL = lib.appendingPathComponent("Logs/MicMonitor", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("app.log")
        queue.sync {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            openHandle()
        }
    }

    func log(_ message: String) {
        let line = "[\(tsFormatter.string(from: Date()))] \(message)\n"
        osLogger.info("\(message, privacy: .public)")
        queue.async { self.append(line) }
    }

    /// 最近日志行(供诊断信息)
    var recentLines: [String] { queue.sync { tail } }

    private func append(_ line: String) {
        rotateIfNeeded()
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        tail.append(line.trimmingCharacters(in: .newlines))
        if tail.count > maxTailLines { tail.removeFirst(tail.count - maxTailLines) }
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > maxFileSize else { return }
        try? handle?.close()
        let rotated = directoryURL.appendingPathComponent("app.log.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        openHandle()
    }
}
