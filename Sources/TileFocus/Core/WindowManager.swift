import Foundation
import AppKit
import Combine

/// TileFocus の中央状態管理クラス
/// すべてのモード・ウィンドウリスト・レイアウト選択を一元管理する
@MainActor
final class WindowManager: ObservableObject {

    // MARK: - Singleton

    static let shared = WindowManager()

    // MARK: - Published State

    /// 現在のアプリモード
    @Published private(set) var currentMode: AppMode = .off

    /// 管理対象のウィンドウリスト（タイリング対象）
    @Published private(set) var managedWindows: [ManagedWindow] = []

    /// 格納済みウィンドウリスト
    @Published private(set) var stagedWindows: [ManagedWindow] = []

    /// 現在選択されているレイアウト（nil = 自動選択）
    @Published private(set) var currentLayout: (any Layout)?

    // MARK: - Internal Components

    private var tilingController: TilingModeController?
    private var focusController: FocusModeController?
    private var stageManager: StageManager?
    private var windowObserver: WindowObserver?
    private var hotKeyManager: HotKeyManager?

    // MARK: - Init

    private init() {}

    // MARK: - Lifecycle

    /// Accessibility 権限確認後に呼び出す
    func startObserving() {
        guard PermissionChecker.isAccessibilityEnabled else {
            print("[WindowManager] Accessibility 権限がありません")
            return
        }

        // コンポーネント初期化
        let stageManager = StageManager()
        self.stageManager = stageManager

        let tilingController = TilingModeController(
            windowManager: self,
            screenManager: ScreenManager()
        )
        self.tilingController = tilingController

        let focusController = FocusModeController(windowManager: self)
        self.focusController = focusController

        // ウィンドウ監視開始
        let observer = WindowObserver()
        observer.delegate = self
        observer.startObserving()
        self.windowObserver = observer

        // ホットキー登録
        let hotKeyManager = HotKeyManager(windowManager: self)
        hotKeyManager.registerHotKeys()
        self.hotKeyManager = hotKeyManager

        // 現在実行中のウィンドウを取得
        refreshWindowList()

        print("[WindowManager] 監視開始")
    }

    // MARK: - Mode Control

    /// モードを切り替える
    func switchMode(to newMode: AppMode) {
        guard newMode != currentMode else {
            // 同じモードなら OFF に切り替え
            deactivateCurrentMode()
            currentMode = .off
            return
        }

        // 現在のモードを無効化
        deactivateCurrentMode()

        currentMode = newMode

        switch newMode {
        case .off:
            break
        case .tiling:
            tilingController?.activate()
        case .focus:
            focusController?.activate()
        }

        print("[WindowManager] モード切り替え: \(newMode.displayName)")
    }

    private func deactivateCurrentMode() {
        switch currentMode {
        case .off:
            break
        case .tiling:
            tilingController?.deactivate()
        case .focus:
            focusController?.deactivate()
        }
    }

    // MARK: - Layout Control

    /// 次のレイアウトプリセットに切り替え
    func nextLayout() {
        tilingController?.nextLayout()
        objectWillChange.send()
    }

    /// 前のレイアウトプリセットに切り替え
    func previousLayout() {
        tilingController?.previousLayout()
        objectWillChange.send()
    }

    func setCurrentLayout(_ layout: (any Layout)?) {
        currentLayout = layout
    }

    // MARK: - Stage Control

    /// フォーカス中のウィンドウを格納
    func stageFocusedWindow() {
        guard currentMode != .off else { return }
        guard let focused = getFocusedWindow() else { return }
        stageWindow(focused)
    }

    /// ウィンドウを格納する
    func stageWindow(_ window: ManagedWindow) {
        stageManager?.stage(window: window, windowManager: self)
    }

    /// 格納ウィンドウを復帰させる
    func unstageWindow(_ window: ManagedWindow) {
        stageManager?.unstage(window: window, windowManager: self)
    }

    /// 全格納ウィンドウを復帰
    func unstageAllWindows() {
        stageManager?.unstageAll(windowManager: self)
    }

    // MARK: - Window List Management

    /// ウィンドウリストを再取得
    func refreshWindowList() {
        let running = NSWorkspace.shared.runningApplications
        var windows: [ManagedWindow] = []

        for app in running {
            guard app.activationPolicy == .regular,
                  let localizedName = app.localizedName else { continue }

            let pid = app.processIdentifier
            let axWindows = AccessibilityHelper.getWindows(for: pid)

            for axWindow in axWindows {
                guard let frame = AccessibilityHelper.getFrame(of: axWindow) else { continue }
                let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""
                let windowID = AccessibilityHelper.getWindowID(of: axWindow) ?? 0

                let managed = ManagedWindow(
                    pid: pid,
                    windowID: windowID,
                    title: title,
                    appName: localizedName,
                    bundleIdentifier: app.bundleIdentifier,
                    frame: frame
                )
                windows.append(managed)
            }
        }

        managedWindows = windows
        print("[WindowManager] ウィンドウリスト更新: \(windows.count) 件")
    }

    /// ウィンドウを追加（新規作成時）
    func addWindow(_ window: ManagedWindow) {
        guard !managedWindows.contains(window) else { return }
        managedWindows.append(window)
        if currentMode == .tiling {
            tilingController?.retile()
        }
    }

    /// ウィンドウを削除（閉じた時）
    func removeWindow(id: String) {
        managedWindows.removeAll { $0.id == id }
        stagedWindows.removeAll { $0.id == id }
        if currentMode == .tiling {
            tilingController?.retile()
        }
    }

    /// 格納リストを更新する（StageManager から呼ばれる）
    func updateStagedWindows(_ windows: [ManagedWindow]) {
        stagedWindows = windows
    }

    /// タイリング対象リストを更新する（StageManager から呼ばれる）
    func updateManagedWindows(_ windows: [ManagedWindow]) {
        managedWindows = windows
    }

    // MARK: - Helpers

    /// 現在フォーカスされているウィンドウを取得
    private func getFocusedWindow() -> ManagedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        return managedWindows.first { $0.pid == pid }
    }
}

// MARK: - WindowObserverDelegate

extension WindowManager: WindowObserverDelegate {
    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectWindowCreated window: ManagedWindow
    ) {
        Task { @MainActor in
            addWindow(window)
        }
    }

    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectWindowClosed windowID: String
    ) {
        Task { @MainActor in
            removeWindow(id: windowID)
        }
    }

    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectWindowMoved window: ManagedWindow
    ) {
        Task { @MainActor in
            if let index = managedWindows.firstIndex(where: { $0.id == window.id }) {
                managedWindows[index].frame = window.frame
            }
        }
    }
}
