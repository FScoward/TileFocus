import Foundation
import AppKit

/// アプリのウィンドウ 1 件を表すモデル
struct ManagedWindow: Identifiable, Hashable {
    /// ウィンドウの一意な識別子（appPID + windowID の組み合わせ）
    let id: String

    /// ウィンドウを所有するアプリのプロセス ID
    let pid: pid_t

    /// CGWindowID（スクリーンショット等に使用）
    let windowID: CGWindowID

    /// ウィンドウのタイトル
    var title: String

    /// アプリ名
    var appName: String

    /// アプリのバンドル識別子
    var bundleIdentifier: String?

    /// 現在のウィンドウフレーム（Accessibility 座標系: 左上原点）
    var frame: CGRect

    /// ウィンドウの状態
    var state: WindowState

    /// 格納前のフレーム（復帰時に使用）
    var frameBeforeStaging: CGRect?

    /// リサイズに失敗したことがあるか（画面共有やアスペクト比固定ウィンドウなどの考慮用）
    var isResizeFailed: Bool

    /// 前回の配置で指示された理想のサイズ
    var lastIdealSize: CGSize?

    // MARK: - Init

    init(
        pid: pid_t,
        windowID: CGWindowID,
        title: String,
        appName: String,
        bundleIdentifier: String? = nil,
        frame: CGRect,
        state: WindowState = .tiled,
        isResizeFailed: Bool = false,
        lastIdealSize: CGSize? = nil
    ) {
        self.id = "\(pid)-\(windowID)"
        self.pid = pid
        self.windowID = windowID
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
        self.state = state
        self.isResizeFailed = isResizeFailed
        self.lastIdealSize = lastIdealSize
    }

    // MARK: - Hashable

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
    }
}
