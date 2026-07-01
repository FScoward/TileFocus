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
    @Published private(set) var masterWindowID: String? {
        didSet {
            if let activeScreen = getActiveScreen() {
                let key = AccessibilityHelper.getActiveSpaceUUID(for: activeScreen) ?? activeScreen.identifier
                if !key.isEmpty {
                    if let masterWindowID {
                        masterWindowIDsBySpace[key] = masterWindowID
                        Log.debug("WindowManager", "masterWindowID didSet: space=\(key) masterWindowID=\(masterWindowID)")
                    } else {
                        masterWindowIDsBySpace.removeValue(forKey: key)
                    }
                } else {
                    Log.warn("WindowManager", "masterWindowID didSet: key が空のため保存をスキップしました")
                }
            }
        }
    }

    /// ユーザーがドラッグ＆ドロップで並べ替えたウィンドウIDの順序
    @Published var customWindowOrder: [String] = [] {
        didSet {
            if !isBatchingLayoutStateUpdate {
                triggerLayoutUpdate()
            }
        }
    }

    /// 上部格納バーが展開されているかどうか
    @Published var isStagedWindowsBarExpanded: Bool = false

    /// Focus Mode の現在のスタイル（中央・左・右メイン、個別設定が無い場合のデフォルト）
    @Published var focusStyle: FocusStyle = .centered {
        didSet {
            if currentMode == .focus || currentMode == .float {
                focusController?.scheduleLayoutUpdate()
            }
        }
    }

    /// 指定されたスクリーンの現在アクティブな仮想スペースに対応する FocusStyle を取得する
    func focusStyle(for screen: NSScreen) -> FocusStyle {
        if let spaceUUID = AccessibilityHelper.getActiveSpaceUUID(for: screen), !spaceUUID.isEmpty {
            let key = spaceUUID
            if let raw = AppSettings.shared.focusStylesByMonitor[key],
               let style = FocusStyle(rawValue: raw) {
                return style
            }
        }
        
        // 仮想スペースごとの設定が無い場合、従来のモニターIDキーでの設定をフォールバックとして試す
        let monitorKey = screen.identifier
        if let raw = AppSettings.shared.focusStylesByMonitor[monitorKey],
           let style = FocusStyle(rawValue: raw) {
            return style
        }
        
        return focusStyle
    }

    /// 指定されたスクリーンの現在アクティブな仮想スペースに対応する FocusStyle を更新する
    func setFocusStyle(_ style: FocusStyle, for screen: NSScreen) {
        let key: String
        if let spaceUUID = AccessibilityHelper.getActiveSpaceUUID(for: screen), !spaceUUID.isEmpty {
            key = spaceUUID
        } else {
            key = screen.identifier
        }
        
        var dict = AppSettings.shared.focusStylesByMonitor
        dict[key] = style.rawValue
        AppSettings.shared.focusStylesByMonitor = dict
        
        // レイアウト更新のトリガー
        if currentMode == .focus || currentMode == .float {
            focusController?.scheduleLayoutUpdate()
        }
        objectWillChange.send()
    }

    private func triggerLayoutUpdate() {
        guard !isSpaceSwitching else {
            Log.debug("WindowManager", "スペース切り替え中のためレイアウト更新をスキップ")
            return
        }

        switch currentMode {
        case .tiling:
            tilingController?.retile()
        case .focus, .float:
            focusController?.scheduleLayoutUpdate()
        case .off:
            break
        }
    }

    func updateLayoutState(customWindowOrder: [String], focusedWindowID: String?, masterWindowID: String?) {
        isBatchingLayoutStateUpdate = true
        self.customWindowOrder = customWindowOrder
        if currentMode == .focus || currentMode == .float {
            self.focusedWindowID = focusedWindowID
            self.masterWindowID = masterWindowID
            focusController?.updateLayoutSelection(focusedID: focusedWindowID, masterID: masterWindowID)
        }
        isBatchingLayoutStateUpdate = false
        triggerLayoutUpdate()
    }


    // MARK: - Internal Components

    private var tilingController: TilingModeController?
    private var focusController: FocusModeController?
    private var stageManager: StageManager?
    private var windowObserver: WindowObserver?
    private var hotKeyManager: HotKeyManager?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var closedWindowReconciliationTimer: Timer?
    /// 仮想スペースUUID（またはモニターID）ごとのマスターウィンドウIDの記憶
    private var masterWindowIDsBySpace: [String: String] = [:]
    private var tilingGuardGeneration: UInt64 = 0
    private var isBatchingLayoutStateUpdate = false
    var isSpaceSwitching: Bool = false
    #if DEBUG
    var isTestingMode: Bool = false
    #endif

    // MARK: - Init

    #if DEBUG
    init() {}
    #else
    private init() {}
    #endif

    deinit {
        closedWindowReconciliationTimer?.invalidate()
    }

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

        // 仮想デスクトップ（操作スペース）切り替えの監視
        let spaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isSpaceSwitching = true
                // 仮想スペース切り替え直後はOS側の状態が不安定なため、0.4 秒のディレイを設ける
                try? await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
                Log.info("WindowManager", "仮想デスクトップの切り替えを検知しました。ウィンドウリストを再構成します。")
                self.refreshWindowList()
                DimmingManager.shared.updateFocusedWindowRect()
                
                // スペース切り替えに伴う AX の遅延通知を吸収するため、少し遅らせて false に戻す。
                // ここでレイアウトを再適用すると、移動先スペースの既存ウィンドウ位置を勝手に変更してしまう。
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2秒待機
                self.isSpaceSwitching = false
                Log.info("WindowManager", "仮想スペース切り替えガードを解除しました。")
            }
        }
        self.workspaceObservers = [spaceToken]

        // 現在実行中のウィンドウを取得
        refreshWindowList()
        startClosedWindowReconciliation()

        print("[WindowManager] 監視開始")
    }

    // MARK: - Mode Control

    /// モードを切り替える
    func switchMode(to newMode: AppMode) {
        guard newMode != currentMode else {
            // 同じモードなら OFF に切り替え
            deactivateCurrentMode()
            currentMode = .off
            DimmingManager.shared.updateDimmingState()
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
        case .focus, .float:
            focusController?.activate()
        }

        DimmingManager.shared.updateDimmingState()

        print("[WindowManager] モード切り替え: \(newMode.displayName)")
    }

    private func deactivateCurrentMode() {
        switch currentMode {
        case .off:
            break
        case .tiling:
            tilingController?.deactivate()
        case .focus, .float:
            focusController?.deactivate()
        }
        DimmingManager.shared.updateDimmingState()
    }

    // MARK: - Tiling In Progress Flag

    /// タイリング適用中かどうか（移動通知の無限ループ防止用）
    func setTilingInProgress(_ inProgress: Bool) {
        if inProgress {
            tilingGuardGeneration &+= 1
        }
        windowObserver?.isTiling = inProgress
    }

    /// AX API による移動・リサイズ直後の遅延通知を、自分の操作として吸収する。
    func finishTilingInProgressAfterWindowSettles(
        delay: TimeInterval = 1.5,
        afterSync: (() -> Void)? = nil
    ) {
        let generation = tilingGuardGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard generation == self.tilingGuardGeneration else {
                Log.debug("WindowManager", "古いウィンドウ移動ガード解除をスキップ generation=\(generation) current=\(self.tilingGuardGeneration)")
                return
            }
            self.syncActualFrames()
            self.setTilingInProgress(false)
            DimmingManager.shared.updateFocusedWindowRect()
            Log.debug("WindowManager", "setTilingInProgress(false) 完了 (ウィンドウ移動通知の吸収完了)")
            afterSync?()
        }
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
        case .focus, .float:
            // Focus & Float Mode: FocusModeController に委譲
            Log.info(tag, "  \(currentMode.displayName) → switchMainWindow(to: \(managed.id))")
            focusController?.switchMainWindow(to: managed.id)
        case .off:
            break
        }
    }

    /// 現在のマスターウィンドウの情報を返す
    var masterWindow: ManagedWindow? {
        if currentMode == .focus || currentMode == .float {
            return (managedWindows + stagedWindows).first { $0.id == masterWindowID }
        } else {
            return managedWindows.first { $0.state != .staged }
        }
    }

    /// Focus Mode でフォーカスウィンドウを切り替える（MenuBar などから呼ばれる）
    func switchFocusedWindow(to windowID: String) {
        guard currentMode == .focus || currentMode == .float else {
            Log.warn("WindowManager", "switchFocusedWindow: Focus/Float Mode でないためスキップ")
            return
        }
        Log.info("WindowManager", "switchFocusedWindow(to: \(windowID))")
        focusedWindowID = windowID
        focusController?.switchMainWindow(to: windowID)
    }

    /// Focus/Float Mode において、ウィンドウをアクティブにするが、マスター（王冠）は切り替えない（通常クリック時など）
    func activateWindowWithoutChangingMaster(to windowID: String) {
        guard currentMode == .focus || currentMode == .float else {
            Log.warn("WindowManager", "activateWindowWithoutChangingMaster: Focus/Float Mode でないためスキップ")
            return
        }
        Log.info("WindowManager", "activateWindowWithoutChangingMaster(to: \(windowID))")
        focusedWindowID = windowID
        focusController?.switchFocusedWindowOnly(to: windowID)
        
        // 物理的にウィンドウを最前面にする
        if let window = (managedWindows + stagedWindows).first(where: { $0.id == windowID }),
           let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
            AccessibilityHelper.focus(window: axWindow)
        }
    }

    /// Focus/Float Mode において、指定されたウィンドウをマスター（王冠）ウィンドウに設定し、フォーカスも当てる
    func setMasterWindow(to windowID: String) {
        guard currentMode == .focus || currentMode == .float else {
            Log.warn("WindowManager", "setMasterWindow: Focus/Float Mode でないためスキップ")
            return
        }
        Log.info("WindowManager", "setMasterWindow(to: \(windowID))")
        focusedWindowID = windowID
        focusController?.switchMainWindow(to: windowID)
        
        // 物理的にウィンドウを最前面にする
        if let window = (managedWindows + stagedWindows).first(where: { $0.id == windowID }),
           let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
            AccessibilityHelper.focus(window: axWindow)
        }
    }

    /// 物理キーボードで Control + Shift が押されているかを確実に判定する
    func isControlShiftPressed() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return flags.contains(.maskControl) && flags.contains(.maskShift)
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
        guard currentMode == .focus || currentMode == .float else { return }
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
        #if DEBUG
        if isTestingMode { return }
        #endif
        let activeSpaceIDs = AccessibilityHelper.getActiveSpaceWindowIDs()
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        let settings = AppSettings.shared
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
            if settings.isAutoPlacementExcluded(bundleIdentifier: app.bundleIdentifier, appName: localizedName) {
                Log.debug("WindowManager", "自動配置の対象外アプリのためスキップ: \(localizedName) bundleIdentifier=\(app.bundleIdentifier ?? "nil")")
                continue
            }

            // isTileable でフィルタリング（標準ウィンドウ・リサイズ可能・非最小化）
            let axWindows = AccessibilityHelper.getWindows(for: pid)
                .filter { AccessibilityHelper.isTileable($0) }

            guard !axWindows.isEmpty else { continue }

            // 各アプリ内でメインウィンドウを先頭にソート
            let sortedWins = axWindows.sorted { a, _ in
                AccessibilityHelper.isMainWindow(a)
            }

            for axWindow in sortedWins {
                let windowID = AccessibilityHelper.getWindowID(of: axWindow) ?? 0
                // 現在アクティブな仮想スペース上に存在するウィンドウのみ対象とする
                guard activeSpaceIDs.contains(windowID) else { continue }

                guard let frame = AccessibilityHelper.getFrame(of: axWindow) else { continue }
                let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""

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
            guard !settings.isAutoPlacementExcluded(bundleIdentifier: staged.bundleIdentifier, appName: staged.appName) else { return false }
            // アプリは起動しているが、ウィンドウがまだ実在しているか
            let axWindows = AccessibilityHelper.getWindows(for: staged.pid)
            return axWindows.contains { axWin in
                AccessibilityHelper.getWindowID(of: axWin) == staged.windowID
            }
        }
        stagedWindows = validStaged
        stageManager?.syncStagedWindows(validStaged)

        managedWindows = windows
        
        // 仮想スペースの切り替え、または現在のフォーカスウィンドウが実在しない場合、フォーカスウィンドウを更新
        let all = windows + stagedWindows
        if isSpaceSwitching || focusedWindowID == nil || !all.contains(where: { $0.id == focusedWindowID }) {
            if let frontmostApp = NSWorkspace.shared.frontmostApplication {
                let frontmostPid = frontmostApp.processIdentifier
                if let activeFocusedWindow = windows.first(where: { $0.pid == frontmostPid }) {
                    focusedWindowID = activeFocusedWindow.id
                } else {
                    focusedWindowID = windows.first?.id
                }
            } else {
                focusedWindowID = windows.first?.id
            }
            Log.info("WindowManager", "仮想スペース移動またはウィンドウ消失に伴いフォーカスウィンドウを自動設定: \(focusedWindowID ?? "nil")")
        }
        
        // 仮想スペース切り替え時やウィンドウリスト更新時に、現在のスペース用のマスターウィンドウIDを復帰させる
        restoreMasterWindowIDForActiveSpace()

        print("[WindowManager] ウィンドウリスト更新: \(windows.count) 件 (front=\(frontPid.map(String.init) ?? "none"))")
        for (i, w) in windows.enumerated() {
            print("  [\(i)] \(w.appName) - \(w.title) frame=\(w.frame)")
        }
    }

    /// 現在アクティブな操作スクリーンを特定する
    /// (1) 現在のマウスカーソルの位置が含まれるスクリーンを優先
    /// (2) 判定できない場合はフォーカスされているウィンドウのあるスクリーン
    /// (3) 最終フォールバックとしてメインスクリーン
    private func getActiveScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if NSMouseInRect(mouseLocation, screen.frame, false) {
                return screen
            }
        }
        
        let screenManager = ScreenManager()
        if let focusedID = focusedWindowID,
           let focusedWindow = (managedWindows + stagedWindows).first(where: { $0.id == focusedID }) {
            let frame = focusedWindow.frameBeforeStaging ?? focusedWindow.frame
            return screenManager.screen(containingAXFrame: frame)
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 現在のアクティブなスペースに保存されているマスターウィンドウIDを復元する
    private func restoreMasterWindowIDForActiveSpace() {
        guard let activeScreen = getActiveScreen() else { return }
        let key = AccessibilityHelper.getActiveSpaceUUID(for: activeScreen) ?? activeScreen.identifier
        
        guard !key.isEmpty else {
            Log.warn("WindowManager", "restoreMasterWindowIDForActiveSpace: key が空文字のため処理をスキップします")
            return
        }
        
        Log.debug("WindowManager", "restoreMasterWindowIDForActiveSpace: key=\(key) savedMasterID=\(masterWindowIDsBySpace[key] ?? "nil")")
        
        if let savedMasterID = masterWindowIDsBySpace[key] {
            // 保存されていたマスターウィンドウIDをそのまま復元する。
            // 注意: ここでウィンドウリスト（managedWindows / stagedWindows）に実在するかチェックしてはならない。
            // スペース移動直後はウィンドウリストが遅延更新されるため、まだ新しいスペースのウィンドウが
            // リストに反映されていない場合がある。その状態で「見つからない」と判定すると、
            // フォールバックロジックが走り、勝手に別のウィンドウがマスターに割り当てられてしまう。
            if masterWindowID != savedMasterID {
                Log.info("WindowManager", "アクティブスペースのマスターウィンドウIDを復元: \(savedMasterID)")
                masterWindowID = savedMasterID
            }
            // フォーカスウィンドウも復元されたマスターに合わせることで、切り替え後の初期イベントによる誤上書きを防ぐ
            if focusedWindowID != savedMasterID {
                Log.info("WindowManager", "フォーカスウィンドウも復元されたマスターに合わせます: \(savedMasterID)")
                focusedWindowID = savedMasterID
            }
            return
        }
        
        // 以下は、そもそもこのスペースに対して保存されたマスターが存在しない場合のみ到達する
        
        // Float Mode では自動的なマスター割り当て（フォーカスウィンドウのマスター化）は行わない
        if currentMode == .float {
            masterWindowID = nil
            return
        }
        
        // clickOnly 設定時のみ、自動的に現在フォーカスされているウィンドウ等をマスター候補とする
        let trigger = AppSettings.shared.crownSwapTrigger
        if trigger == .clickOnly {
            let remaining = managedWindows.filter { $0.state != .staged }
            if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                masterWindowID = nextMaster.id
            } else {
                masterWindowID = nil
            }
        } else {
            // ctrlShiftClick の場合は勝手にマスターを設定せず nil とする
            masterWindowID = nil
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
        // 現在アクティブな仮想スペース上に存在するかチェック
        let activeSpaceIDs = AccessibilityHelper.getActiveSpaceWindowIDs()
        guard activeSpaceIDs.contains(window.windowID) else { return }

        managedWindows.append(window)
        guard !isSpaceSwitching else {
            Log.debug("WindowManager", "スペース切り替え中のウィンドウ追加のため、レイアウト更新をスキップ: \(window.appName)")
            return
        }
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
        stageManager?.syncStagedWindows(stagedWindows)
        if focusedWindowID == id {
            focusedWindowID = nil
            DimmingManager.shared.updateFocusedWindowRect()
        }
        guard !isSpaceSwitching else {
            Log.debug("WindowManager", "スペース切り替え中のウィンドウ削除のため、レイアウト更新をスキップ: \(id)")
            return
        }
        if currentMode == .tiling {
            tilingController?.retile()
        } else if currentMode == .focus || currentMode == .float {
            focusController?.handleWindowClosed(id: id)
        }
    }

    private func startClosedWindowReconciliation() {
        guard closedWindowReconciliationTimer == nil else { return }

        closedWindowReconciliationTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeClosedWindowsIfNeeded()
            }
        }
    }

    private func removeClosedWindowsIfNeeded() {
        #if DEBUG
        if isTestingMode { return }
        #endif
        guard !isSpaceSwitching else { return }

        let trackedWindows = managedWindows + stagedWindows
        guard !trackedWindows.isEmpty else { return }

        let trackedPids = Set(trackedWindows.map(\.pid))
        var existingIDs = Set<String>()

        for pid in trackedPids {
            guard NSRunningApplication(processIdentifier: pid) != nil else { continue }
            for axWindow in AccessibilityHelper.getWindows(for: pid) {
                guard let windowID = AccessibilityHelper.getWindowID(of: axWindow) else { continue }
                existingIDs.insert("\(pid)-\(windowID)")
            }
        }

        let closedIDs = Set(trackedWindows.map(\.id)).subtracting(existingIDs)
        guard !closedIDs.isEmpty else { return }

        Log.info("WindowManager", "存在しないウィンドウを検知しました: \(closedIDs.sorted().joined(separator: ", "))")
        for id in closedIDs.sorted() {
            removeWindow(id: id)
        }
    }

    /// 指定された pid のすべてのウィンドウを削除（アプリ終了時など）
    func removeWindows(for pid: pid_t) {
        managedWindows.removeAll { $0.pid == pid }
        stagedWindows.removeAll { $0.pid == pid }
        stageManager?.syncStagedWindows(stagedWindows)
        
        if let focusedID = focusedWindowID, focusedID.hasPrefix("\(pid)-") {
            focusedWindowID = nil
            DimmingManager.shared.updateFocusedWindowRect()
        }

        guard !isSpaceSwitching else {
            Log.debug("WindowManager", "スペース切り替え中のアプリ終了通知のため、レイアウト更新をスキップ: pid=\(pid)")
            return
        }
        
        if currentMode == .tiling {
            tilingController?.retile()
        } else if currentMode == .focus || currentMode == .float {
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
        DimmingManager.shared.updateFocusedWindowRect()
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

    #if DEBUG
    /// テスト用に FocusModeController を直接設定する
    func setFocusControllerForTesting(_ controller: FocusModeController) {
        self.focusController = controller
    }
    #endif

    // MARK: - Helpers

    /// 現在フォーカスされているウィンドウを取得
    func getFocusedWindow() -> ManagedWindow? {
        if let focusedWindowID,
           let focused = (managedWindows + stagedWindows).first(where: { $0.id == focusedWindowID }) {
            return focused
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return managedWindows.first { $0.pid == app.processIdentifier }
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
            guard !isSpaceSwitching else {
                Log.debug("WindowManager", "スペース切り替え中の移動通知のためフレーム更新をスキップ: \(window.id)")
                return
            }
            if let index = managedWindows.firstIndex(where: { $0.id == window.id }) {
                managedWindows[index].frame = window.frame
                if focusedWindowID == window.id {
                    DimmingManager.shared.updateFocusedWindowRect()
                }
            }
        }
    }

    nonisolated func windowObserver(
        _ observer: WindowObserver,
        didDetectFocusChanged pid: pid_t,
        title: String
    ) {
        Task { @MainActor in
            if currentMode == .focus || currentMode == .float {
                focusController?.handleFocusChanged(pid: pid, title: title)
            } else if currentMode == .tiling {
                let managed = managedWindows
                if let match = managed.first(where: { $0.pid == pid && ($0.title == title || title.isEmpty) }) ?? managed.first(where: { $0.pid == pid }) {
                    if match.id != focusedWindowID {
                        focusedWindowID = match.id
                        DimmingManager.shared.updateFocusedWindowRect()
                    }
                }
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

    nonisolated func windowObserverDidNeedWindowListRefresh(_ observer: WindowObserver) {
        Task { @MainActor in
            refreshWindowList()
            triggerLayoutUpdate()
        }
    }
}
