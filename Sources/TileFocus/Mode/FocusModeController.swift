import Foundation
import AppKit
import Carbon

/// Focus Mode のロジックを担当するコントローラー
@MainActor
final class FocusModeController {

    nonisolated private static let tag = "FocusModeController"

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = FocusLayout()
    private let topBarController = StageTopBarController()

    // MARK: - State

    private var focusedWindowID: String?
    private var masterWindowID: String?
    private var floatModeOriginalFrames: [String: CGRect] = [:]
    private var focusHistory: [String] = []
    private var mainAcceptedSizesByWindowID: [String: CGSize] = [:]
    private var isPostSettleRepairing = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var updateWorkItem: DispatchWorkItem?
    /// applyLayout() 実行中フラグ
    /// この間は didActivateApplicationNotification による focusedWindowID 更新を抑制する
    private var isApplyingLayout: Bool = false
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func activate() {
        Log.info(Self.tag, "activate() 開始")
        
        // 全モニターに上部バーを表示
        if let windowManager {
            topBarController.show(windowManager: windowManager)
        }

        updateFocusedWindow()
        applyLayout()

        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Log.info(Self.tag, "didActivateApplication: \(app.localizedName ?? "?")")
            Task { @MainActor in
                // applyLayout() 実行中またはスペース切り替え中は通知による上書きを抑制
                guard !self.isApplyingLayout, let windowManager = self.windowManager, !windowManager.isSpaceSwitching else {
                    Log.debug(Self.tag, "didActivateApplication: スキップ (applyLayout中、またはスペース切り替え中)")
                    return
                }
                self.updateFocusedWindow(runningApp: app)
            }
        }

        // マウスクリック監視を追加（Control + Shift + ウィンドウクリックで王冠設定）
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor in
                self.handleMouseClick(event: event, at: mouseLocation)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let mouseLocation = NSEvent.mouseLocation
            Task { @MainActor in
                self.handleMouseClick(event: event, at: mouseLocation)
            }
            return event
        }

        workspaceObservers = [activateToken]
        Log.info(Self.tag, "activate() 完了 - NSWorkspace / マウスクリック 監視開始")
    }

    func deactivate() {
        Log.info(Self.tag, "deactivate()")
        updateWorkItem?.cancel()
        updateWorkItem = nil

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []

        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        
        // 上部バーを非表示にする
        topBarController.hide()
        
        // すべての格納ウィンドウを画面上に復帰させる
        if let windowManager {
            windowManager.unstageAllWindows()
        }

        // Float モードで元のフレームに戻しきれなかったものを復帰させる
        if let windowManager {
            let all = windowManager.managedWindows + windowManager.stagedWindows
            for (windowID, originalFrame) in floatModeOriginalFrames {
                if let window = all.first(where: { $0.id == windowID }),
                   let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
                    Log.info(Self.tag, "[FloatMode] deactivate 時のフレーム復帰: \(window.appName) -> \(originalFrame)")
                    windowManager.setTilingInProgress(true)
                    AccessibilityHelper.setFrame(originalFrame, to: axWindow)
                    windowManager.finishTilingInProgressAfterWindowSettles()
                }
            }
        }
        floatModeOriginalFrames = [:]

        focusedWindowID = nil
        setMasterWindowID(nil)
    }

    // MARK: - Focus Control

    private func updateFocusedWindow(runningApp: NSRunningApplication? = nil) {
        guard let windowManager else { return }
        guard let frontApp = runningApp ?? NSWorkspace.shared.frontmostApplication else {
            Log.warn(Self.tag, "updateFocusedWindow: frontmostApplication = nil")
            return
        }

        // TileFocus 自身がフロントになった場合は無視
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            Log.debug(Self.tag, "updateFocusedWindow: TileFocus 自身 → スキップ")
            return
        }

        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "?"
        Log.info(Self.tag, "updateFocusedWindow: \(appName) (pid=\(pid))")

        let axWindows = AccessibilityHelper.getWindows(for: pid)
        let mainAX = axWindows.first { AccessibilityHelper.isMainWindow($0) } ?? axWindows.first
        let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""

        Log.debug(Self.tag, "  AXウィンドウ数=\(axWindows.count), mainTitle=\"\(mainTitle)\"")

        // managedWindows 内で対応するウィンドウを探す
        let managedWindows = windowManager.managedWindows
        Log.debug(Self.tag, "  managedWindows 数=\(managedWindows.count)")

        if let match = managedWindows.first(where: {
            $0.pid == pid && ($0.title == mainTitle || mainTitle.isEmpty)
        }) {
            if match.id != focusedWindowID {
                Log.info(Self.tag, "  フォーカス変更: \"\(match.appName) - \(match.title)\" (id=\(match.id))")
                setFocusedWindowID(match.id)
            } else {
                Log.debug(Self.tag, "  フォーカス変更なし (already \(match.id))")
            }
        } else if let first = managedWindows.first(where: { $0.pid == pid }) {
            if first.id != focusedWindowID {
                Log.warn(Self.tag, "  タイトル不一致 → PID マッチで \"\(first.appName) - \(first.title)\"")
                setFocusedWindowID(first.id)
            }
        } else {
            Log.warn(Self.tag, "  managedWindowsに \(appName)(pid=\(pid)) が存在しない → refreshWindowList を実行")
            windowManager.refreshWindowList()
            // リフレッシュ後に再度検索
            if let match = windowManager.managedWindows.first(where: { $0.pid == pid }) {
                setFocusedWindowID(match.id)
                Log.info(Self.tag, "  リフレッシュ後マッチ: \"\(match.appName)\"")
            }
        }
    }

    func switchMainWindow(to windowID: String) {
        Log.info(Self.tag, "switchMainWindow() 引数 windowID=\(windowID)")
        Log.info(Self.tag, "  現在の focusedWindowID=\(focusedWindowID ?? "nil"), masterWindowID=\(masterWindowID ?? "nil")")
        Log.info(Self.tag, "  isApplyingLayout=\(isApplyingLayout)")

        // managedWindows の状態も記録
        if let windowManager {
            let windows = windowManager.managedWindows
            Log.info(Self.tag, "  managedWindows(\(windows.count)件):")
            for (i, w) in windows.enumerated() {
                let isTarget = w.id == windowID ? " ← ターゲット" : ""
                let isCurrent = w.id == focusedWindowID ? " ← 現在フォーカス" : ""
                let isMaster = w.id == masterWindowID ? " ← 現在マスター" : ""
                Log.info(Self.tag, "    [\(i)] \"\(w.appName) - \(w.title)\" id=\(w.id)\(isTarget)\(isCurrent)\(isMaster)")
            }
        }

        if let windowManager, windowManager.currentMode == .float, masterWindowID == windowID {
            Log.info(Self.tag, "  [FloatMode] すでにマスターのため王冠を解除します: \(windowID)")
            setMasterWindowID(nil)
            applyLayout()
            return
        }

        guard masterWindowID != windowID || focusedWindowID != windowID else {
            Log.debug(Self.tag, "switchMainWindow: 変更なし (already master and focused)")
            return
        }
        Log.info(Self.tag, "  マスター切り替え: \(masterWindowID ?? "nil") → \(windowID)")
        setMasterWindowID(windowID)
        setFocusedWindowID(windowID)
        applyLayout()
    }

    /// フォーカスウィンドウのみを切り替え、マスター（王冠）は変更しない
    func switchFocusedWindowOnly(to id: String) {
        guard let windowManager, (windowManager.currentMode == .focus || windowManager.currentMode == .float) else { return }
        guard focusedWindowID != id else {
            Log.debug(Self.tag, "  フォーカス切り替え（マスター変更なし）: 変更なし \(id)")
            return
        }
        Log.info(Self.tag, "  フォーカス切り替え（マスター変更なし）: \(focusedWindowID ?? "nil") → \(id)")
        setFocusedWindowID(id)
        applyLayout()
    }

    func updateLayoutSelection(focusedID: String?, masterID: String?) {
        focusedWindowID = focusedID
        masterWindowID = masterID
    }

    /// WindowObserver からフォーカス変更の通知を受け取る（同じアプリ内のウィンドウ切り替え等に対応）
    func handleFocusChanged(pid: pid_t, title: String) {
        guard !isApplyingLayout, let windowManager, !windowManager.isSpaceSwitching else {
            Log.debug(Self.tag, "handleFocusChanged: applyLayout中またはスペース切り替え中のためスキップ")
            return
        }

        let managed = windowManager.managedWindows

        if let match = managed.first(where: {
            $0.pid == pid && ($0.title == title || title.isEmpty)
        }) ?? managed.first(where: { $0.pid == pid }) {
            
            if match.id != focusedWindowID {
                Log.info(Self.tag, "handleFocusChanged: フォーカス自動変更 \"\(match.appName) - \(match.title)\" (id=\(match.id))")
                setFocusedWindowID(match.id)
            }
        }
    }

    /// ウィンドウが閉じられた時の処理
    func handleWindowClosed(id: String) {
        Log.info(Self.tag, "handleWindowClosed() windowID=\(id)")
        focusHistory.removeAll { $0 == id }
        if masterWindowID == id {
            let trigger = AppSettings.shared.crownSwapTrigger
            if trigger == .clickOnly {
                if let windowManager {
                    let remaining = windowManager.managedWindows.filter { $0.id != id && $0.state != .staged }
                    if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                        setMasterWindowID(nextMaster.id)
                    } else {
                        setMasterWindowID(nil)
                    }
                } else {
                    setMasterWindowID(nil)
                }
            } else {
                Log.info(Self.tag, "  マスターウィンドウが閉じられたため、マスターを解除 (ctrlShiftClick設定)")
                setMasterWindowID(nil)
            }
            Log.info(Self.tag, "  マスターウィンドウが閉じられたため、新しいマスターに設定: \(masterWindowID ?? "nil")")
        }
        scheduleLayoutUpdate()
    }

    @MainActor
    func handleMouseClick(event: NSEvent, at mouseLocation: NSPoint) {
        let flags = event.modifierFlags
        let isCtrlShiftPressed = flags.contains(.control) && flags.contains(.shift)
        
        let trigger = AppSettings.shared.crownSwapTrigger
        
        // ctrlShiftClick または clickOnly の場合のみクリックを処理
        guard isCtrlShiftPressed || trigger == .clickOnly else { return }

        // もし設定が ctrlShiftClick なのに、修飾キーが押されていなければ無視
        if trigger == .ctrlShiftClick && !isCtrlShiftPressed { return }

        let axPoint = screenManager.appKitToAX(mouseLocation)
        
        Log.info(Self.tag, "handleMouseClick: クリック検知 mouseLocation=\(mouseLocation), axPoint=\(axPoint)")
        
        guard let axWindow = AccessibilityHelper.getWindow(at: axPoint) else {
            Log.debug(Self.tag, "  マウス位置にウィンドウ要素が見つかりません")
            return
        }
        
        guard let clickWindowID = AccessibilityHelper.getWindowID(of: axWindow) else {
            Log.debug(Self.tag, "  取得したウィンドウ要素 of CGWindowID を取得できません")
            return
        }
        
        guard let pid = AccessibilityHelper.getPid(of: axWindow) else {
            Log.debug(Self.tag, "  取得したウィンドウ要素の PID を取得できません")
            return
        }
        
        guard let windowManager else { return }
        
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows
        let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""
        
        if let match = allWindows.first(where: { $0.windowID == clickWindowID }) ??
                       allWindows.first(where: { $0.pid == pid && $0.title == title }) {
            Log.info(Self.tag, "  → ウィンドウ特定: \"\(match.appName) - \(match.title)\" (id=\(match.id))")
            
            if windowManager.stagedWindows.contains(where: { $0.id == match.id }) {
                windowManager.unstageWindow(match)
            }
            
            windowManager.setMasterWindow(to: match.id)
        } else {
            Log.debug(Self.tag, "  → マッチする管理ウィンドウがありません (pid=\(pid), title=\"\(title)\", windowID=\(clickWindowID))")
        }
    }

    // MARK: - Private Helpers

    /// focusedWindowID を更新し WindowManager の @Published 値にも反映させる
    private func setFocusedWindowID(_ id: String?) {
        focusedWindowID = id
        windowManager?.updateFocusedWindowID(id)
        if let id {
            updateFocusHistory(with: id)
        }
    }

    /// masterWindowID を更新し WindowManager の @Published 値にも反映させる
    private func setMasterWindowID(_ id: String?) {
        masterWindowID = id
        windowManager?.updateMasterWindowID(id)
    }

    private func updateFocusHistory(with id: String) {
        focusHistory.removeAll { $0 == id }
        focusHistory.insert(id, at: 0)
        if focusHistory.count > 50 {
            focusHistory.removeLast()
        }
        Log.debug(Self.tag, "updateFocusHistory: \(focusHistory)")
    }

    // MARK: - Layout Application

    func scheduleLayoutUpdate(debounce: TimeInterval = 0.1) {
        updateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyLayout()
        }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func applyFloatLayout() {
        guard let windowManager else { return }
        
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows
        guard !allWindows.isEmpty else { return }
        
        // 1. 王冠を外されたウィンドウのフレームを復帰させる
        for window in allWindows {
            if window.id != masterWindowID {
                if let originalFrame = floatModeOriginalFrames[window.id] {
                    if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
                        Log.info(Self.tag, "[FloatMode] 王冠が外れたため元のフレームに復帰: \(window.appName) -> \(originalFrame)")
                        windowManager.setTilingInProgress(true)
                        AccessibilityHelper.setFrame(originalFrame, to: axWindow)
                        windowManager.finishTilingInProgressAfterWindowSettles()
                    }
                    floatModeOriginalFrames.removeValue(forKey: window.id)
                }
            }
        }
        
        // 2. 現在の王冠ウィンドウ（masterWindowID）を中央に特定%で表示する
        if let masterID = masterWindowID,
           let masterWindow = allWindows.first(where: { $0.id == masterID }) {
            
            // 現在アクティブなスペースに実在するかチェック（別スペースからの引きずり出し防止）
            let activeSpaceIDs = AccessibilityHelper.getActiveSpaceWindowIDs()
            guard activeSpaceIDs.contains(masterWindow.windowID) else {
                Log.warn(Self.tag, "[FloatMode] 王冠ウィンドウが現在のアクティブスペースに存在しないため、配置をスキップします: \(masterWindow.appName)")
                return
            }
            
            if let axWindow = AccessibilityHelper.findWindow(for: masterWindow.pid, windowID: masterWindow.windowID, title: masterWindow.title) {
                // 現在の物理的なフレームを取得して、まだ保存されていなければ保存する
                if floatModeOriginalFrames[masterID] == nil {
                    if let currentFrame = AccessibilityHelper.getFrame(of: axWindow) {
                        floatModeOriginalFrames[masterID] = currentFrame
                        Log.info(Self.tag, "[FloatMode] 王冠付与前のフレームを保存: \(masterWindow.appName) -> \(currentFrame)")
                    }
                }
                
                // 現在アクティブなスクリーンを特定
                let currentFrame = AccessibilityHelper.getFrame(of: axWindow) ?? masterWindow.frame
                let screen = screenManager.screen(containingAXFrame: currentFrame)
                let visibleFrame = screenManager.visibleFrameInAX(for: screen)
                
                // 特定% (幅・高さそれぞれ個別の比率にする)
                let widthRatio = AppSettings.shared.floatModeWidthRatio
                let heightRatio = AppSettings.shared.floatModeHeightRatio
                let targetWidth = visibleFrame.width * widthRatio
                let targetHeight = visibleFrame.height * heightRatio
                let targetX = visibleFrame.minX + (visibleFrame.width - targetWidth) / 2
                let targetY = visibleFrame.minY + (visibleFrame.height - targetHeight) / 2
                
                let targetFrame = CGRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
                Log.info(Self.tag, "[FloatMode] 王冠ウィンドウを中央に配置: \(masterWindow.appName) -> \(targetFrame)")
                
                windowManager.setTilingInProgress(true)
                AccessibilityHelper.setFrame(targetFrame, to: axWindow)
                windowManager.finishTilingInProgressAfterWindowSettles()
                
                // アクティブにする（フォーカスされているのがマスターの場合のみ）
                if focusedWindowID == masterID {
                    AccessibilityHelper.focus(window: axWindow)
                }
            }
        }
    }

    func applyLayout() {
        isApplyingLayout = true
        defer { isApplyingLayout = false }
        guard let windowManager else { return }
        guard !windowManager.isSpaceSwitching else {
            Log.debug(Self.tag, "applyLayout: スペース切り替え中のためスキップ")
            return
        }
        
        if windowManager.currentMode == .float {
            applyFloatLayout()
            DimmingManager.shared.updateFocusedWindowRect()
            return
        }
        
        // staged も含めた全ウィンドウを対象とする（ホバーバーの表示順と同期するため）
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows

        // マスターウィンドウが格納されている、消失している、あるいは未設定の場合の自動補正
        let trigger = AppSettings.shared.crownSwapTrigger
        if let currentMasterID = masterWindowID {
            let isStaged = windowManager.stagedWindows.contains(where: { $0.id == currentMasterID })
            let exists = allWindows.contains(where: { $0.id == currentMasterID })
            if isStaged || !exists {
                if trigger == .clickOnly {
                    let remaining = windowManager.managedWindows.filter { $0.state != .staged }
                    if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                        Log.info(Self.tag, "マスターウィンドウが格納または消失したため、新マスターに自動移譲: \(nextMaster.appName) (id=\(nextMaster.id))")
                        setMasterWindowID(nextMaster.id)
                    } else {
                        setMasterWindowID(nil)
                    }
                } else {
                    Log.info(Self.tag, "マスターウィンドウが格納または消失したため、マスターを解除 (ctrlShiftClick設定)")
                    setMasterWindowID(nil)
                }
            }
        } else if !allWindows.isEmpty {
            if trigger == .clickOnly {
                let remaining = windowManager.managedWindows.filter { $0.state != .staged }
                if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                    Log.info(Self.tag, "マスターウィンドウが未設定のため、新マスターに自動設定: \(nextMaster.appName) (id=\(nextMaster.id))")
                    setMasterWindowID(nextMaster.id)
                }
            }
        }

        Log.info(Self.tag, "applyLayout() 開始 focusedID=\(focusedWindowID ?? "nil") masterID=\(masterWindowID ?? "nil") 対象=\(allWindows.count)枚")

        guard !allWindows.isEmpty else {
            Log.warn(Self.tag, "applyLayout: 対象ウィンドウなし")
            return
        }

        // スクリーンを取得
        let screens = NSScreen.screens.sorted { s1, s2 in
            if s1.frame.origin.x != s2.frame.origin.x {
                return s1.frame.origin.x < s2.frame.origin.x
            }
            return s1.frame.origin.y > s2.frame.origin.y
        }
        
        // Zオーダーの順序揺らぎを防ぐため、まずはそのまま ordered とする
        let ordered = allWindows
        
        // スクリーン別グループ化
        var screenGroups: [[ManagedWindow]] = Array(repeating: [], count: max(screens.count, 1))
        for window in ordered {
            var resolvedWindow = window
            var currentFrame = window.frame
            if window.state != .staged {
                if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title),
                   let realFrame = AccessibilityHelper.getFrame(of: axWindow) {
                    currentFrame = realFrame
                }
            } else {
                if let beforeStaging = window.frameBeforeStaging {
                    currentFrame = beforeStaging
                }
            }
            resolvedWindow.frame = currentFrame
            
            let placement = screenPlacement(for: currentFrame, in: screens)
            let isSelected = window.id == focusedWindowID || window.id == masterWindowID
            if placement.visibleRatio < 0.12 && !isSelected {
                Log.info(Self.tag, "  ほぼ画面外のため通常配置から除外: \"\(window.appName) - \(window.title)\" frame=\(currentFrame) visibleRatio=\(placement.visibleRatio)")
                continue
            }

            let idx = placement.index
            screenGroups[idx].append(resolvedWindow)
        }


        // フェーズ1: ホバーバーと同じソート順を適用し、完全分割の格納・復帰（Stage/Unstage）チェック
        var hasStateChanged = false
        var activeGroups: [Int: [ManagedWindow]] = [:]
        var screenMainCounts: [Int: Int] = [:]

        for (si, group) in screenGroups.enumerated() {
            guard !group.isEmpty else { continue }
            
            let screen = screens[si]
            let monitorStyle = windowManager.focusStyle(for: screen)
            
            // group を ホバーバー (allWindowsForScreen) と完全に同じロジックでソート
            var sortedGroup = group
            if let masterID = masterWindowID,
               let masterIndex = sortedGroup.firstIndex(where: { $0.id == masterID }) {
                let master = sortedGroup.remove(at: masterIndex)
                let sortedOthers = sortedGroup.sorted { w1, w2 in
                    let idx1 = windowManager.customWindowOrder.firstIndex(of: w1.id)
                    let idx2 = windowManager.customWindowOrder.firstIndex(of: w2.id)
                    switch (idx1, idx2) {
                    case (.some(let i1), .some(let i2)):
                        return i1 < i2
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        if w1.appName != w2.appName {
                            return w1.appName < w2.appName
                        }
                        return w1.title < w2.title
                    }
                }
                sortedGroup = [master] + sortedOthers
            } else {
                sortedGroup = sortedGroup.sorted { w1, w2 in
                    let idx1 = windowManager.customWindowOrder.firstIndex(of: w1.id)
                    let idx2 = windowManager.customWindowOrder.firstIndex(of: w2.id)
                    switch (idx1, idx2) {
                    case (.some(let i1), .some(let i2)):
                        return i1 < i2
                    case (.some, .none):
                        return true
                    case (.none, .some):
                        return false
                    case (.none, .none):
                        if w1.appName != w2.appName {
                            return w1.appName < w2.appName
                        }
                        return w1.title < w2.title
                    }
                }
            }

            // メインウィンドウの数を決定
            let mainCount: Int
            switch monitorStyle {
            case .splitCentered:
                mainCount = sortedGroup.count >= 2 ? 2 : 1
            case .absoluteSplit2:
                mainCount = min(2, sortedGroup.count)
            case .absoluteSplit3:
                mainCount = min(3, sortedGroup.count)
            default:
                mainCount = 1
            }
            screenMainCounts[si] = mainCount
            
            let mains = Array(sortedGroup.prefix(mainCount))

            if monitorStyle == .absoluteSplit2 || monitorStyle == .absoluteSplit3 {
                // mains (上位2/3個) の中で staged になっているものを unstage する
                for window in mains {
                    if window.state == .staged {
                        Log.info(Self.tag, "完全分割の上位に入るため復帰: \"\(window.appName) - \(window.title)\"")
                        windowManager.unstageWindow(window)
                        hasStateChanged = true
                    }
                }
                let notPlacedCount = max(0, sortedGroup.count - mainCount)
                if notPlacedCount > 0 {
                    Log.info(Self.tag, "完全分割の表示枠を超えた \(notPlacedCount) 件は自動格納しません")
                }
                activeGroups[si] = mains.filter { $0.state != .staged }
            } else {
                // 通常モードでは staged でないもののみを画面に配置
                activeGroups[si] = sortedGroup.filter { $0.state != .staged }
            }
        }
        
        if hasStateChanged {
            // 格納・復帰によって managedWindows / stagedWindows が更新され、
            // 自動的に次の applyLayout がスケジュールされるため、今回の配置処理はスキップする
            return
        }

        // フェーズ2: ウィンドウの物理配置適用
        // タイリング中フラグ
        windowManager.setTilingInProgress(true)
        // フォーカスするウィンドウの AXUIElement
        var axWindowToFocus: AXUIElement? = nil
        var appliedFrames: [(id: String, frame: CGRect)] = []
        var appliedIdealSizes: [(id: String, size: CGSize)] = []
        struct SidePlacement {
            let id: String
            let name: String
            let axWindow: AXUIElement
            let isLeft: Bool
            let targetFrame: CGRect
            var frame: CGRect
            let resistedHeight: Bool
        }

        for (si, _) in screenGroups.enumerated() {
            guard let activeGroup = activeGroups[si], !activeGroup.isEmpty else { continue }
            let mainCount = screenMainCounts[si] ?? 1
            
            let screen = screens[si]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            Log.info(Self.tag, "  Screen[\(si)] \(activeGroup.count)枚 AXFrame=\(screenAXFrame)")

            let monitorStyle = windowManager.focusStyle(for: screen)
            var activeLayout = layout
            activeLayout.style = monitorStyle
            let gap = activeLayout.gap
            let minSideWindowHeight = activeLayout.minSideWindowHeight

            let idealFrames = activeLayout.calculateFrames(windowCount: activeGroup.count, screenFrame: screenAXFrame)

            // 左右サイドバーの Y 座標追跡
            var currentLeftY = screenAXFrame.minY + gap.outer
            var currentRightY = screenAXFrame.minY + gap.outer

            var actualLeftX: CGFloat? = nil
            var actualLeftW: CGFloat? = nil
            var actualRightX: CGFloat? = nil
            var actualRightW: CGFloat? = nil
            var sidePlacements: [SidePlacement] = []

            // 現在アクティブなスペースのウィンドウIDを取得
            let activeSpaceIDs = AccessibilityHelper.getActiveSpaceWindowIDs()

            for (i, window) in activeGroup.enumerated() {
                // 現在アクティブなスペースに実在するかチェック（別スペースからの引きずり出し防止）
                guard activeSpaceIDs.contains(window.windowID) else {
                    Log.warn(Self.tag, "    ⚠️ ウィンドウ \"\(window.appName) - \(window.title)\" は現在のアクティブスペースに存在しないため配置をスキップします")
                    continue
                }
                
                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) else {
                    Log.error(Self.tag, "    ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\(window.title)")
                    continue
                }

                if AccessibilityHelper.isMinimized(axWindow) {
                    Log.info(Self.tag, "    → 最小化を解除: \"\(window.appName)\"")
                    AccessibilityHelper.restore(window: axWindow)
                }

                var targetFrame: CGRect
                var role: String
                var isLeftWindow = false
                var isRightWindow = false

                let isMain = i < mainCount

                if isMain {
                    let idealFrame = idealFrames[min(i, idealFrames.count - 1)]
                    let actualSize = window.frame.size
                    let rememberedMainSize = mainAcceptedSizesByWindowID[window.id]
                    let lastIdealLooksLikeCurrentMain = window.lastIdealSize.map {
                        abs($0.width - idealFrame.width) <= 5 && abs($0.height - idealFrame.height) <= 5
                    } ?? false
                    let usesConstrainedSize: Bool
                    if window.isResizeFailed, rememberedMainSize != nil, lastIdealLooksLikeCurrentMain {
                        usesConstrainedSize = true
                    } else if window.isResizeFailed {
                        usesConstrainedSize = lastIdealLooksLikeCurrentMain
                    } else {
                        usesConstrainedSize = false
                    }

                    if usesConstrainedSize {
                        let constrainedSize = rememberedMainSize ?? actualSize
                        let targetW = min(max(100, constrainedSize.width), idealFrame.width)
                        let targetH = min(max(100, constrainedSize.height), idealFrame.height)
                        targetFrame = CGRect(
                            x: idealFrame.midX - targetW / 2,
                            y: idealFrame.minY,
                            width: targetW,
                            height: targetH
                        )
                        Log.debug(Self.tag, "    MAIN constraint \"\(window.appName) - \(window.title)\": ideal=\(idealFrame.size) actual=\(actualSize) rememberedMain=\(rememberedMainSize.map { "\($0)" } ?? "nil") lastIdeal=\(window.lastIdealSize.map { "\($0)" } ?? "nil") lastIdealLooksLikeCurrentMain=\(lastIdealLooksLikeCurrentMain) resizeFailed=\(window.isResizeFailed)")
                    } else {
                        targetFrame = idealFrame
                        if window.isResizeFailed {
                            Log.debug(Self.tag, "    MAIN probe \"\(window.appName) - \(window.title)\": MAIN成功サイズ未記憶のため理想サイズを再試行 ideal=\(idealFrame.size) actual=\(actualSize) lastIdeal=\(window.lastIdealSize.map { "\($0)" } ?? "nil")")
                        }
                    }
                    role = "MAIN_\(i)"
                } else {
                    // SIDE ウィンドウ
                    let idealFrame = idealFrames[min(i, idealFrames.count - 1)]

                    // リサイズに失敗したウィンドウは、次回以降も通らない理想サイズを投げ続けない。
                    // Terminal の文字セル単位リサイズや、アプリ固有の最小/最大サイズで位置まで補正されるため、
                    // 失敗済みの場合は直近の実サイズをこのウィンドウの制約サイズとして扱う。
                    let actualSize = window.frame.size
                    let constrainedSize: CGSize
                    let usesConstrainedSize: Bool
                    if window.isResizeFailed {
                        constrainedSize = actualSize
                        usesConstrainedSize = true
                    } else {
                        constrainedSize = idealFrame.size
                        usesConstrainedSize = false
                    }

                    let isLeft: Bool
                    switch monitorStyle {
                    case .centered:
                        isLeft = (i % 2 == 1)
                    case .leftMain:
                        isLeft = false
                    case .rightMain:
                        isLeft = true
                    case .splitCentered:
                        isLeft = ((i - 2) % 2 == 0)
                    case .absoluteSplit2, .absoluteSplit3:
                        isLeft = false
                    }

                    let currentY = isLeft ? currentLeftY : currentRightY

                    // 残り高さの計算
                    let remainingH = (screenAXFrame.minY + screenAXFrame.height - gap.outer) - currentY

                    let requiredH = max(minSideWindowHeight, constrainedSize.height)
                    let targetW = max(100, constrainedSize.width)
                    let canPlace = remainingH >= minSideWindowHeight

                    Log.debug(Self.tag, "    SIDE constraint \"\(window.appName) - \(window.title)\": ideal=\(idealFrame.size) actual=\(actualSize) lastIdeal=\(window.lastIdealSize.map { "\($0)" } ?? "nil") resizeFailed=\(window.isResizeFailed) remainingH=\(remainingH) requiredH=\(requiredH)")

                    if canPlace {
                        let columnX = isLeft ? (actualLeftX ?? idealFrame.origin.x) : (actualRightX ?? idealFrame.origin.x)
                        let columnW = isLeft ? (actualLeftW ?? idealFrame.width) : (actualRightW ?? idealFrame.width)
                        let finalW = usesConstrainedSize ? min(targetW, columnW) : columnW
                        let finalX = isLeft ? columnX : columnX + max(0, columnW - finalW)
                        let finalH = min(constrainedSize.height, remainingH)

                        targetFrame = CGRect(
                            x: finalX,
                            y: currentY,
                            width: finalW,
                            height: finalH
                        )
                        role = isLeft ? "SIDE_L[\(i)]" : "SIDE_R[\(i)]"
                        if isLeft {
                            isLeftWindow = true
                        } else {
                            isRightWindow = true
                        }
                    } else {
                        Log.info(Self.tag, "    残り領域が最小高さ未満のため配置スキップ: \"\(window.appName) - \(window.title)\" remainingH=\(remainingH) minSideWindowHeight=\(minSideWindowHeight)")
                        continue
                    }
                }

                let originalTargetFrame = targetFrame
                let originalRole = role
                let idealFrameForLog = idealFrames[min(i, idealFrames.count - 1)]
                Log.debug(Self.tag, "    placement request role=\(role) isMain=\(isMain) id=\(window.id) cachedFrame=\(window.frame) cachedResizeFailed=\(window.isResizeFailed) cachedLastIdeal=\(window.lastIdealSize.map { "\($0)" } ?? "nil") idealFrame=\(idealFrameForLog) screenAXFrame=\(screenAXFrame)")
                Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" → \(targetFrame)")
                var success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)

                // 実際の配置後のフレームを取得して追跡
                var actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
                let primaryActualFrame = actualFrame
                Log.debug(Self.tag, "    placement primary result role=\(role) success=\(success) request=\(targetFrame) actual=\(actualFrame)")

                if !success && isMain {
                    let idealFrame = idealFrames[min(i, idealFrames.count - 1)]
                    let fallbackW = min(max(100, actualFrame.width), idealFrame.width)
                    let fallbackH = min(max(100, actualFrame.height), idealFrame.height)
                    let screenMinX = screenAXFrame.minX + gap.outer
                    let screenMaxX = screenAXFrame.minX + screenAXFrame.width - gap.outer
                    let fallbackX = min(max(idealFrame.midX - fallbackW / 2, screenMinX), screenMaxX - fallbackW)
                    targetFrame = CGRect(
                        x: fallbackX,
                        y: idealFrame.minY,
                        width: fallbackW,
                        height: fallbackH
                    )
                    role = "MAIN_FALLBACK[\(i)]"
                    Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" resize fallback → \(targetFrame) originalRole=\(originalRole) originalTarget=\(originalTargetFrame) actualAfterIdeal=\(actualFrame)")
                    success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
                    actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
                    Log.debug(Self.tag, "    placement main fallback result role=\(role) success=\(success) fallbackRequest=\(targetFrame) actual=\(actualFrame)")
                }

                if isMain, success {
                    recordMainAcceptedSize(windowID: window.id, size: actualFrame.size)
                }

                if !success && (isLeftWindow || isRightWindow) {
                    let bottomLimit = screenAXFrame.minY + screenAXFrame.height - gap.outer
                    let topLimit = screenAXFrame.minY + gap.outer
                    let leftLimit = screenAXFrame.minX + gap.outer
                    let rightLimit = screenAXFrame.minX + screenAXFrame.width - gap.outer
                    let availableHeight = bottomLimit - topLimit
                    let fitTolerance: CGFloat = 12
                    var shouldApplyFallback = false
                    let fallbackSize = CGSize(
                        width: min(max(100, actualFrame.width), rightLimit - leftLimit),
                        height: min(max(minSideWindowHeight, actualFrame.height), availableHeight)
                    )

                    if actualFrame.height <= availableHeight + fitTolerance {
                        let desiredX = isLeftWindow ? targetFrame.minX : targetFrame.maxX - actualFrame.width
                        let fittedX = min(max(desiredX, leftLimit), rightLimit - actualFrame.width)
                        let fittedY = min(max(targetFrame.minY, topLimit), bottomLimit - actualFrame.height)
                        let fittedOrigin = CGPoint(x: fittedX, y: fittedY)
                        Log.info(Self.tag, "    実サイズを採用して画面内に再配置: \"\(window.appName) - \(window.title)\" actual=\(actualFrame) fittedOrigin=\(fittedOrigin) bounds=(x:\(leftLimit)-\(rightLimit), y:\(topLimit)-\(bottomLimit)) tolerance=\(fitTolerance)")
                        if abs(actualFrame.minX - fittedOrigin.x) > fitTolerance || abs(actualFrame.minY - fittedOrigin.y) > fitTolerance {
                            _ = AccessibilityHelper.setPositionOnly(of: axWindow, to: fittedOrigin)
                            actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? actualFrame
                        }
                        success = true
                    } else if targetFrame.minY + fallbackSize.height <= bottomLimit {
                        let desiredX = isLeftWindow ? targetFrame.minX : targetFrame.maxX - fallbackSize.width
                        let fallbackX = min(max(desiredX, leftLimit), rightLimit - fallbackSize.width)
                        targetFrame = CGRect(
                            x: fallbackX,
                            y: min(max(targetFrame.minY, topLimit), bottomLimit - fallbackSize.height),
                            width: fallbackSize.width,
                            height: fallbackSize.height
                        )
                        role = isLeftWindow ? "SIDE_L_FALLBACK[\(i)]" : "SIDE_R_FALLBACK[\(i)]"
                        Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" 画面内サイズで再要求 → \(targetFrame) actualAfterPrimary=\(actualFrame)")
                        shouldApplyFallback = true
                    } else {
                        let desiredX = isLeftWindow ? targetFrame.minX : targetFrame.maxX - fallbackSize.width
                        let fallbackX = min(max(desiredX, leftLimit), rightLimit - fallbackSize.width)
                        targetFrame = CGRect(
                            x: fallbackX,
                            y: topLimit,
                            width: fallbackSize.width,
                            height: fallbackSize.height
                        )
                        role = isLeftWindow ? "SIDE_L_FALLBACK_CLAMP[\(i)]" : "SIDE_R_FALLBACK_CLAMP[\(i)]"
                        Log.warn(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" 実サイズが表示領域より大きいため上端固定で再要求 → \(targetFrame) actualAfterPrimary=\(actualFrame) availableHeight=\(availableHeight)")
                        shouldApplyFallback = true
                    }

                    if shouldApplyFallback {
                        success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
                        actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
                        Log.debug(Self.tag, "    placement side fallback result role=\(role) success=\(success) fallbackRequest=\(targetFrame) actual=\(actualFrame)")
                        if !success {
                            let finalX = min(max(actualFrame.minX, leftLimit), rightLimit - actualFrame.width)
                            let finalY = actualFrame.height <= availableHeight + fitTolerance
                                ? min(max(targetFrame.minY, topLimit), bottomLimit - actualFrame.height)
                                : topLimit
                            let finalOrigin = CGPoint(x: finalX, y: finalY)
                            Log.info(Self.tag, "    fallback後もサイズが丸められたため位置だけ画面内へ補正: \"\(window.appName) - \(window.title)\" from=\(actualFrame.origin) to=\(finalOrigin) actualSize=\(actualFrame.size)")
                            _ = AccessibilityHelper.setPositionOnly(of: axWindow, to: finalOrigin)
                            actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? actualFrame
                            success = actualFrame.minY >= topLimit - fitTolerance && actualFrame.minY <= bottomLimit + fitTolerance
                        }
                    }
                }

                let resizeFailedAfterUpdate = !success
                windowManager.setResizeFailed(id: window.id, failed: !success)
                Log.info(Self.tag, "    placement final role=\(role) id=\(window.id) success=\(success) resizeFailedAfterUpdate=\(resizeFailedAfterUpdate) rememberedMainSize=\(mainAcceptedSizesByWindowID[window.id].map { "\($0)" } ?? "nil") finalActual=\(actualFrame) originalRole=\(originalRole) originalTarget=\(originalTargetFrame)")

                // 配置後のフレームを記録 (実際の配置フレームを使うことで、stale なキャッシュを防ぐ)
                appliedFrames.append((id: window.id, frame: actualFrame))
                if isLeftWindow || isRightWindow {
                    let resistedHeight = abs(primaryActualFrame.height - originalTargetFrame.height) > 12
                    sidePlacements.append(SidePlacement(
                        id: window.id,
                        name: "\(window.appName) - \(window.title)",
                        axWindow: axWindow,
                        isLeft: isLeftWindow,
                        targetFrame: originalTargetFrame,
                        frame: actualFrame,
                        resistedHeight: resistedHeight
                    ))
                }

                // 今回指定した理想サイズを記録
                let idealSz = idealFrames[min(i, idealFrames.count - 1)].size
                appliedIdealSizes.append((id: window.id, size: idealSz))

                if i == 0 {
                    // 左側サイドバーの幅決定（通常のメイン、または2分割メインの左側）
                    let leftX = screenAXFrame.minX + gap.outer
                    let leftMaxX = actualFrame.minX - gap.inner
                    actualLeftX = leftX
                    actualLeftW = max(100, leftMaxX - leftX)
                    
                    // splitCentered, absoluteSplit2, absoluteSplit3 以外の場合は、i == 0 の右端が右サイドバーの左端になる
                    if monitorStyle != .splitCentered && monitorStyle != .absoluteSplit2 && monitorStyle != .absoluteSplit3 {
                        let rightX = actualFrame.maxX + gap.inner
                        let screenMaxX = screenAXFrame.minX + screenAXFrame.width - gap.outer
                        actualRightX = rightX
                        actualRightW = max(100, screenMaxX - rightX)
                    }
                } else if i == 1 && monitorStyle == .splitCentered {
                    // splitCentered の場合のみ、i == 1（中央メイン右側）の右端が右サイドバーの左端になる
                    let rightX = actualFrame.maxX + gap.inner
                    let screenMaxX = screenAXFrame.minX + screenAXFrame.width - gap.outer
                    actualRightX = rightX
                    actualRightW = max(100, screenMaxX - rightX)
                }

                // 実際の高さに基づいて Y 座標を更新する
                if isLeftWindow {
                    currentLeftY += actualFrame.height + gap.inner
                } else if isRightWindow {
                    currentRightY += actualFrame.height + gap.inner
                }

                // フォーカスウィンドウの AX を記録（まだ focus() しない）
                if window.id == focusedWindowID {
                    axWindowToFocus = axWindow
                    Log.debug(Self.tag, "    → focus 予定: \"\(window.appName)\"")
                }
            }

            func repackSideColumn(_ entries: [SidePlacement], sideName: String) {
                guard entries.count > 1 else { return }

                let topLimit = screenAXFrame.minY + gap.outer
                let bottomLimit = screenAXFrame.minY + screenAXFrame.height - gap.outer
                let leftLimit = screenAXFrame.minX + gap.outer
                let rightLimit = screenAXFrame.minX + screenAXFrame.width - gap.outer
                let availableHeight = bottomLimit - topLimit
                let totalGap = gap.inner * CGFloat(entries.count - 1)
                let totalHeight = entries.reduce(CGFloat.zero) { $0 + $1.frame.height } + totalGap

                var targetHeights = entries.map(\.frame.height)
                if totalHeight > availableHeight + 1 {
                    var overflow = totalHeight - availableHeight
                    let shrinkableIndexes = entries.indices.filter { !entries[$0].resistedHeight }
                    let capacity = shrinkableIndexes.reduce(CGFloat.zero) { partial, idx in
                        partial + max(0, targetHeights[idx] - minSideWindowHeight)
                    }

                    if capacity > 0 {
                        for idx in shrinkableIndexes {
                            let itemCapacity = max(0, targetHeights[idx] - minSideWindowHeight)
                            guard itemCapacity > 0 else { continue }
                            let reduction = min(itemCapacity, overflow * (itemCapacity / capacity))
                            targetHeights[idx] -= reduction
                        }
                        let newTotal = targetHeights.reduce(CGFloat.zero, +) + totalGap
                        overflow = max(0, newTotal - availableHeight)
                    }

                    Log.info(Self.tag, "    \(sideName) column repack: totalHeight=\(totalHeight) availableHeight=\(availableHeight) remainingOverflow=\(overflow) shrinkable=\(shrinkableIndexes.count)")
                }

                var currentY = topLimit
                for (idx, entry) in entries.enumerated() {
                    let desiredHeight = targetHeights[idx]
                    let desiredWidth = min(max(100, entry.frame.width), rightLimit - leftLimit)
                    let desiredX = entry.isLeft ? entry.targetFrame.minX : entry.targetFrame.maxX - desiredWidth
                    let fittedX = min(max(desiredX, leftLimit), rightLimit - desiredWidth)
                    let desiredFrame = CGRect(x: fittedX, y: currentY, width: desiredWidth, height: desiredHeight)

                    var didResize = false
                    if abs(entry.frame.height - desiredHeight) > 8 || abs(entry.frame.width - desiredWidth) > 8 {
                        Log.info(Self.tag, "    \(sideName) column repack resize: \"\(entry.name)\" from=\(entry.frame) to=\(desiredFrame)")
                        _ = AccessibilityHelper.moveAndResize(window: entry.axWindow, to: desiredFrame.origin, size: desiredFrame.size)
                        didResize = true
                    } else if abs(entry.frame.minX - desiredFrame.minX) > 8 || abs(entry.frame.minY - desiredFrame.minY) > 8 {
                        Log.info(Self.tag, "    \(sideName) column repack position: \"\(entry.name)\" from=\(entry.frame.origin) to=\(desiredFrame.origin) size=\(entry.frame.size)")
                        _ = AccessibilityHelper.setPositionOnly(of: entry.axWindow, to: desiredFrame.origin)
                    }

                    var actual = AccessibilityHelper.getFrame(of: entry.axWindow) ?? desiredFrame
                    let finalY = actual.height <= availableHeight
                        ? min(max(currentY, topLimit), bottomLimit - actual.height)
                        : topLimit
                    let finalX = min(max(fittedX, leftLimit), rightLimit - actual.width)
                    if abs(actual.minX - finalX) > 8 || abs(actual.minY - finalY) > 8 {
                        Log.info(Self.tag, "    \(sideName) column repack final position: \"\(entry.name)\" from=\(actual.origin) to=(\(finalX), \(finalY)) actualSize=\(actual.size) didResize=\(didResize)")
                        _ = AccessibilityHelper.setPositionOnly(of: entry.axWindow, to: CGPoint(x: finalX, y: finalY))
                        actual = AccessibilityHelper.getFrame(of: entry.axWindow) ?? actual
                    }

                    appliedFrames.append((id: entry.id, frame: actual))
                    currentY = actual.minY + actual.height + gap.inner
                }
            }

            repackSideColumn(sidePlacements.filter(\.isLeft), sideName: "LEFT")
            repackSideColumn(sidePlacements.filter { !$0.isLeft }, sideName: "RIGHT")
        }

        // ManagedWindow.frame を配置後の値で更新
        windowManager.updateFrames(appliedFrames)
        windowManager.updateLastIdealSizes(appliedIdealSizes)
        Log.debug(Self.tag, "  ManagedWindow.frame 更新: \(appliedFrames.count)件")

        // 全ウィンドウ配置完了後に、フォーカスウィンドウだけ focus() する
        if let axWindowToFocus {
            let focusName = windowManager.managedWindows.first(where: { $0.id == focusedWindowID })?.appName ?? "?"
            Log.info(Self.tag, "  focus() 実行: \"\(focusName)\"")
            AccessibilityHelper.focus(window: axWindowToFocus)
        }

        var intendedFramesByID: [String: CGRect] = [:]
        for entry in appliedFrames {
            intendedFramesByID[entry.id] = entry.frame
        }
        windowManager.finishTilingInProgressAfterWindowSettles { [weak self] in
            self?.verifyPostSettleFrames(intendedFramesByID)
        }

        Log.info(Self.tag, "applyLayout() 完了")
    }

    // MARK: - Private

    private func verifyPostSettleFrames(_ intendedFramesByID: [String: CGRect]) {
        guard let windowManager else { return }
        guard windowManager.currentMode == .focus else { return }
        guard !intendedFramesByID.isEmpty else { return }

        let repairThreshold: CGFloat = 18
        var driftLogs: [String] = []

        for window in windowManager.managedWindows {
            guard let intended = intendedFramesByID[window.id] else { continue }
            let actual = window.frame
            let dx = abs(actual.minX - intended.minX)
            let dy = abs(actual.minY - intended.minY)
            let dw = abs(actual.width - intended.width)
            let dh = abs(actual.height - intended.height)
            let maxDiff = max(dx, dy, dw, dh)
            if maxDiff > repairThreshold {
                driftLogs.append(
                    "\"\(window.appName) - \(window.title)\" diff=(x:\(dx), y:\(dy), w:\(dw), h:\(dh)) intended=\(intended) actual=\(actual)"
                )
            }
        }

        guard !driftLogs.isEmpty else {
            if isPostSettleRepairing {
                Log.info(Self.tag, "post-settle repair 完了: 追加ドリフトなし")
                isPostSettleRepairing = false
            }
            return
        }

        Log.warn(Self.tag, "settle後ドリフト検出: \(driftLogs.joined(separator: " / "))")
        guard !isPostSettleRepairing else {
            Log.warn(Self.tag, "post-settle repair 後もドリフトが残っています。無限再配置を避けるため追加再試行は行いません")
            isPostSettleRepairing = false
            return
        }

        Log.info(Self.tag, "settle後ドリフトを補正するため、1回だけ再配置します")
        isPostSettleRepairing = true
        applyLayout()
    }

    private func screenIndex(for axFrame: CGRect, in screens: [NSScreen]) -> Int {
        screenPlacement(for: axFrame, in: screens).index
    }

    private func recordMainAcceptedSize(windowID: String, size: CGSize) {
        guard size.width >= 100, size.height >= 100 else { return }
        mainAcceptedSizesByWindowID[windowID] = size
        Log.debug(Self.tag, "    MAIN accepted size 記憶: id=\(windowID) size=\(size)")
    }

    private func screenPlacement(for axFrame: CGRect, in screens: [NSScreen]) -> (index: Int, visibleRatio: CGFloat) {
        let appKitFrame = screenManager.axToAppKit(axFrame)
        var bestIndex = 0
        var bestArea: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let intersection = screen.frame.intersection(appKitFrame)
            let area = intersection.width > 0 && intersection.height > 0
                ? intersection.width * intersection.height : 0
            if area > bestArea { bestArea = area; bestIndex = i }
        }

        let windowArea = max(1, appKitFrame.width * appKitFrame.height)
        let visibleRatio = max(0, bestArea) / windowArea

        // どのスクリーンとも交差しない場合（画面外に退避されている場合など）
        if bestArea <= 0 {
            var minDistance = CGFloat.greatestFiniteMagnitude
            for (i, screen) in screens.enumerated() {
                let screenCenterX = screen.frame.midX
                let windowCenterX = appKitFrame.midX
                let dist = abs(screenCenterX - windowCenterX)
                if dist < minDistance {
                    minDistance = dist
                    bestIndex = i
                }
            }
        }

        return (bestIndex, visibleRatio)
    }
}
