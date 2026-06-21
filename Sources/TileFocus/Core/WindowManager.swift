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

    /// Focus Mode で現在フォーカス中のウィンドウ ID（UI 参照用）
    @Published private(set) var focusedWindowID: String?

    /// Focus Mode における現在のマスター（メイン）ウィンドウ ID
    @Published private(set) var masterWindowID: String?

    /// ユーザーがドラッグ＆ドロップで並べ替えたウィンドウIDの順序
    @Published var customWindowOrder: [String] = [] {
        didSet {
            triggerLayoutUpdate()
        }
    }

    /// 上部格納バーが展開されているかどうか
    @Published var isStagedWindowsBarExpanded: Bool = false

    /// Focus Mode の現在のスタイル（中央・左・右メイン、個別設定が無い場合のデフォルト）
    @Published var focusStyle: FocusStyle = .centered {
        didSet {
            if currentMode == .focus {
                focusController?.scheduleLayoutUpdate()
            }
        }
    }

    /// 指定されたスクリーンの FocusStyle を取得する
    func focusStyle(for screen: NSScreen) -> FocusStyle {
        let key = screen.identifier
        if let raw = AppSettings.shared.focusStylesByMonitor[key],
           let style = FocusStyle(rawValue: raw) {
            return style
        }
        return focusStyle
    }

    /// 指定されたスクリーンの FocusStyle を更新する
    func setFocusStyle(_ style: FocusStyle, for screen: NSScreen) {
        let key = screen.identifier
        var dict = AppSettings.shared.focusStylesByMonitor
        dict[key] = style.rawValue
        AppSettings.shared.focusStylesByMonitor = dict
        
        // レイアウト更新のトリガー
        if currentMode == .focus {
            focusController?.scheduleLayoutUpdate()
        }
        objectWillChange.send()
    }

    private func triggerLayoutUpdate() {
        switch currentMode {
        case .tiling:
            tilingController?.retile()
        case .focus:
            focusController?.scheduleLayoutUpdate()
        case .off:
            break
        }
    }


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

    // MARK: - Tiling In Progress Flag

    /// タイリング適用中かどうか（移動通知の無限ループ防止用）
    func setTilingInProgress(_ inProgress: Bool) {
        windowObserver?.isTiling = inProgress
    }

    /// 外部コンポーネントからタイリング再適用をリクエストする
    func requestRetile() {
        guard currentMode == .tiling else { return }
        tilingController?.retile()
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

    // MARK: - Master Window Control

    /// フロントウィンドウをメインに是抜する
    ///
    /// - Tiling Mode: managedWindows 先頭に移動して再タイリング
    /// - Focus Mode : FocusModeController にフォーカス切り替えを通知
    func promoteCurrentWindowToMaster() {
        let tag = "WindowManager"
        Log.info(tag, "promoteCurrentWindowToMaster() 開始 currentMode=\(currentMode.displayName)")
        guard currentMode != .off else {
            Log.warn(tag, "  モードが OFF のためスキップ")
            return
        }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            Log.warn(tag, "  frontmostApplication = nil")
            return
        }
        let frontPid = frontApp.processIdentifier
        Log.info(tag, "  frontApp=\(frontApp.localizedName ?? "?") pid=\(frontPid)")

        // TileFocus 自身は無視
        guard frontPid != ProcessInfo.processInfo.processIdentifier else {
            Log.warn(tag, "  TileFocus 自身のため無視")
            return
        }

        // フロントアプリのメインウィンドウを特定
        let frontAXWindows = AccessibilityHelper.getWindows(for: frontPid)
        Log.info(tag, "  AXウィンドウ数=\(frontAXWindows.count)")
        let mainAX = frontAXWindows.first { AccessibilityHelper.isMainWindow($0) } ?? frontAXWindows.first
        let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""
        Log.info(tag, "  mainTitle=\"\(mainTitle)\"")

        // managedWindows の状態を記録
        Log.info(tag, "  managedWindows(\(managedWindows.count)件):")
        for (i, w) in managedWindows.enumerated() {
            Log.info(tag, "    [\(i)] pid=\(w.pid) \"\(w.appName) - \(w.title)\" id=\(w.id)")
        }

        // managedWindows 内で対応するウィンドウを探す
        guard let managed = managedWindows.first(where: {
            $0.pid == frontPid && ($0.title == mainTitle || mainTitle.isEmpty)
        }) ?? managedWindows.first(where: { $0.pid == frontPid }) else {
            Log.warn(tag, "  フロントウィンドウが管理リストにありません pid=\(frontPid) title=\"\(mainTitle)\"")
            return
        }
        Log.info(tag, "  マッチしたウィンドウ: \"\(managed.appName) - \(managed.title)\" id=\(managed.id)")

        switch currentMode {
        case .tiling:
            // Tiling Mode: リスト先頭に移動して再タイリング
            if let idx = managedWindows.firstIndex(where: { $0.id == managed.id }), idx != 0 {
                let promoted = managedWindows.remove(at: idx)
                managedWindows.insert(promoted, at: 0)
                Log.info(tag, "  Tiling マスター変更: \(promoted.appName) - \(promoted.title)")
                tilingController?.retile()
                objectWillChange.send()
            } else {
                Log.info(tag, "  \(managed.appName) はすでにマスターです")
            }
        case .focus:
            // Focus Mode: FocusModeController に委譲
            Log.info(tag, "  Focus Mode → switchMainWindow(to: \(managed.id))")
            focusController?.switchMainWindow(to: managed.id)
        case .off:
            break
        }
    }

    /// 現在のマスターウィンドウの情報を返す
    var masterWindow: ManagedWindow? {
        if currentMode == .focus {
            return (managedWindows + stagedWindows).first { $0.id == masterWindowID }
        } else {
            return managedWindows.first { $0.state != .staged }
        }
    }

    /// Focus Mode でフォーカスウィンドウを切り替える（MenuBar などから呼ばれる）
    func switchFocusedWindow(to windowID: String) {
        guard currentMode == .focus else {
            Log.warn("WindowManager", "switchFocusedWindow: Focus Mode でないためスキップ")
            return
        }
        Log.info("WindowManager", "switchFocusedWindow(to: \(windowID))")
        focusedWindowID = windowID
        focusController?.switchMainWindow(to: windowID)
    }

    // MARK: - Stage Control

    /// フォーカス中のウィンドウを格納
    func stageFocusedWindow() {
        guard currentMode != .off else { return }
        guard let focused = getFocusedWindow() else { return }
        stageWindow(focused)
    }

    /// ウィンドウを格納する
    func stageWindow(_ window: ManagedWindow, forceDock: Bool = false) {
        stageManager?.stage(window: window, windowManager: self, forceDock: forceDock)
    }

    /// 格納ウィンドウを復帰させる
    func unstageWindow(_ window: ManagedWindow) {
        stageManager?.unstage(window: window, windowManager: self)
    }

    /// Focus Mode においてレイアウトの再計算を要求する
    func requestFocusLayoutUpdate() {
        guard currentMode == .focus else { return }
        focusController?.scheduleLayoutUpdate()
    }

    /// 全格納ウィンドウを復帰
    func unstageAllWindows() {
        stageManager?.unstageAll(windowManager: self)
    }

    // MARK: - Window List Management

    /// ウィンドウリストを再取得
    ///
    /// 順序: フロントアプリのメインウィンドウ → その他のアプリのウィンドウ
    func refreshWindowList() {
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        var windows: [ManagedWindow] = []

        // フロントアプリを先頭に処理するため、並び替え
        var sortedApps = running.filter { app in
            app.processIdentifier != selfPid
                && app.activationPolicy == .regular
                && app.localizedName != nil
        }
        sortedApps.sort { a, b in
            if a.processIdentifier == frontPid { return true }
            if b.processIdentifier == frontPid { return false }
            return false
        }

        for app in sortedApps {
            let pid = app.processIdentifier
            let localizedName = app.localizedName!

            // isTileable でフィルタリング（標準ウィンドウ・リサイズ可能・非最小化）
            let axWindows = AccessibilityHelper.getWindows(for: pid)
                .filter { AccessibilityHelper.isTileable($0) }

            guard !axWindows.isEmpty else { continue }

            // 各アプリ内でメインウィンドウを先頭にソート
            let sortedWins = axWindows.sorted { a, _ in
                AccessibilityHelper.isMainWindow(a)
            }

            for axWindow in sortedWins {
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
 
        // stagedWindows のクリーンアップ（終了済みのアプリや存在しないウィンドウを排除）
        let runningPids = Set(running.map { $0.processIdentifier })
        let validStaged = stagedWindows.filter { staged in
            guard runningPids.contains(staged.pid) else { return false }
            // アプリは起動しているが、ウィンドウがまだ実在しているか
            let axWindows = AccessibilityHelper.getWindows(for: staged.pid)
            return axWindows.contains { axWin in
                AccessibilityHelper.getWindowID(of: axWin) == staged.windowID
            }
        }
        stagedWindows = validStaged
        stageManager?.syncStagedWindows(validStaged)

        managedWindows = windows
        print("[WindowManager] ウィンドウリスト更新: \(windows.count) 件 (front=\(frontPid.map(String.init) ?? "none"))")
        for (i, w) in windows.enumerated() {
            print("  [\(i)] \(w.appName) - \(w.title) frame=\(w.frame)")
        }
    }

    /// ウィンドウを追加（新規作成時）
    func addWindow(_ window: ManagedWindow) {
        // 重複チェック
        guard !managedWindows.contains(window) else { return }
        // 自分自身のプロセスは無視
        guard window.pid != ProcessInfo.processInfo.processIdentifier else { return }
        // 最小サイズフィルタ
        guard window.frame.width >= 100 && window.frame.height >= 100 else { return }

        managedWindows.append(window)
        if currentMode == .tiling {
            tilingController?.retile()
        } else if currentMode == .focus {
            focusController?.scheduleLayoutUpdate()
        }
    }

    /// ウィンドウを削除（閉じた時）
    func removeWindow(id: String) {
        managedWindows.removeAll { $0.id == id }
        stagedWindows.removeAll { $0.id == id }
        if currentMode == .tiling {
            tilingController?.retile()
        } else if currentMode == .focus {
            focusController?.handleWindowClosed(id: id)
        }
    }

    /// 指定された pid のすべてのウィンドウを削除（アプリ終了時など）
    func removeWindows(for pid: pid_t) {
        managedWindows.removeAll { $0.pid == pid }
        stagedWindows.removeAll { $0.pid == pid }
        stageManager?.syncStagedWindows(stagedWindows)
        
        if currentMode == .tiling {
            tilingController?.retile()
        } else if currentMode == .focus {
            requestFocusLayoutUpdate()
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

    /// Focus Mode のフォーカスウィンドウ ID を更新する（FocusModeController から呼ばれる）
    func updateFocusedWindowID(_ id: String?) {
        focusedWindowID = id
    }

    /// Focus Mode のマスターウィンドウ ID を更新する（FocusModeController から呼ばれる）
    func updateMasterWindowID(_ id: String?) {
        masterWindowID = id
    }

    /// ウィンドウのリサイズ成否状態を更新する
    func setResizeFailed(id: String, failed: Bool) {
        if let idx = managedWindows.firstIndex(where: { $0.id == id }) {
            managedWindows[idx].isResizeFailed = failed
        }
    }

    /// 各ウィンドウの理想のサイズを更新する
    func updateLastIdealSizes(_ entries: [(id: String, size: CGSize)]) {
        for entry in entries {
            if let idx = managedWindows.firstIndex(where: { $0.id == entry.id }) {
                managedWindows[idx].lastIdealSize = entry.size
            }
        }
    }

    /// レイアウト適用後の実際のフレームで ManagedWindow.frame を更新する
    /// stale なキャッシュを防ぎ、次回の screenIndex 計算を正確にする
    func updateFrames(_ frames: [(id: String, frame: CGRect)]) {
        for entry in frames {
            if let idx = managedWindows.firstIndex(where: { $0.id == entry.id }) {
                managedWindows[idx].frame = entry.frame
            }
        }
    }

    /// 画面上の実際のウィンドウフレームを AX API から再取得し、現在のキャッシュを一括更新する
    /// タイリングなどの非同期なウィンドウ移動が完了した後に呼び出してキャッシュの完全な同期を保証します
    func syncActualFrames() {
        var updatedFrames: [(id: String, frame: CGRect)] = []
        Log.debug("WindowManager", "syncActualFrames 開始 managedWindows.count=\(managedWindows.count)")
        for window in managedWindows {
            if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title),
               let realFrame = AccessibilityHelper.getFrame(of: axWindow) {
                Log.debug("WindowManager", "  [sync] \"\(window.appName) - \(window.title)\" frame: \(window.frame) -> \(realFrame) (idealSize=\(window.lastIdealSize.map { "\($0)" } ?? "nil") resizeFailed=\(window.isResizeFailed))")
                updatedFrames.append((id: window.id, frame: realFrame))
            } else {
                Log.warn("WindowManager", "  [sync] \"\(window.appName) - \(window.title)\" AXWindow または Frame 取得失敗")
            }
        }
        updateFrames(updatedFrames)
        Log.debug("WindowManager", "syncActualFrames: 実際のフレームで同期完了 (\(updatedFrames.count)件)")
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
        // ユーザーが手動で移動した場合のみフレームを更新（タイリング中は無視）
        Task { @MainActor in
            if let index = managedWindows.firstIndex(where: { $0.id == window.id }) {
                managedWindows[index].frame = window.frame
            }
        }
    }

    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectFocusChanged pid: pid_t,
        title: String
    ) {
        Task { @MainActor in
            if currentMode == .focus {
                focusController?.handleFocusChanged(pid: pid, title: title)
            }
        }
    }

    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectApplicationTerminated pid: pid_t
    ) {
        Task { @MainActor in
            removeWindows(for: pid)
        }
    }
}
