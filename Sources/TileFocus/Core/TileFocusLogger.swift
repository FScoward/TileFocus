import Foundation

/// TileFocus 専用ロガー
///
/// ログ出力先: ~/Library/Logs/TileFocus/tilefocus.log
/// 確認方法: Terminal で `tail -f ~/Library/Logs/TileFocus/tilefocus.log`
final class TileFocusLogger {

    // MARK: - Singleton

    static let shared = TileFocusLogger()

    // MARK: - Log Level

    enum Level: String {
        case debug  = "DEBUG"
        case info   = "INFO "
        case warn   = "WARN "
        case error  = "ERROR"
    }

    // MARK: - State

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.tilefocus.logger", qos: .utility)
    private var fileHandle: FileHandle?

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    // MARK: - Init

    private init() {
        let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/TileFocus")

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        fileURL = logDir.appendingPathComponent("tilefocus.log")

        // ファイルが存在しなければ作成
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()

        // 起動セパレータ
        let sep = "\n" + String(repeating: "=", count: 80) + "\n"
        let start = "  TileFocus 起動: \(Self.dateFormatter.string(from: Date()))\n"
        let end = String(repeating: "=", count: 80) + "\n"
        write(sep + start + end)
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Public API

    func log(_ level: Level = .info, _ component: String, _ message: String, file: String = #file, line: Int = #line) {
        let timestamp = Self.dateFormatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : "bg"
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(thread)] [\(component)] \(message)\n"

        // コンソールにも出力
        print(entry, terminator: "")

        // ファイルに書き込み
        queue.async { [weak self] in
            self?.write(entry)
        }
    }

    func debug(_ component: String, _ message: String) { log(.debug, component, message) }
    func info (_ component: String, _ message: String) { log(.info,  component, message) }
    func warn (_ component: String, _ message: String) { log(.warn,  component, message) }
    func error(_ component: String, _ message: String) { log(.error, component, message) }

    /// ログファイルのパスを返す
    var logFilePath: String { fileURL.path }

    /// ログファイルをクリア
    func clearLog() {
        queue.async { [weak self] in
            guard let self else { return }
            try? "".write(to: self.fileURL, atomically: true, encoding: .utf8)
            self.fileHandle?.seek(toFileOffset: 0)
        }
    }

    // MARK: - Private

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        fileHandle?.write(data)
    }
}

// MARK: - Convenience shorthand

let Log = TileFocusLogger.shared
