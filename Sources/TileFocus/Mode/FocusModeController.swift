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
                // applyLayout() 実行中は通知による上書きを抑制
                guard !self.isApplyingLayout else {
                    Log.debug(Self.tag, "didActivateApplication: applyLayout 中のため スキップ")
                    return
                }
                self.updateFocusedWindow(runningApp: app)
            }
        }

        // マウスクリック監視を追加（Control + Shift + ウィンドウクリックで王冠設定）
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleMouseClick(event: event)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in
                self.handleMouseClick(event: event)
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
                    windowManager.setTilingInProgress(false)
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
        Log.info(Self.tag, "  フォーカス切り替え（マスター変更なし）: \(focusedWindowID ?? "nil") → \(id)")
        setFocusedWindowID(id)
        applyLayout()
    }

    /// WindowObserver からフォーカス変更の通知を受け取る（同じアプリ内のウィンドウ切り替え等に対応）
    func handleFocusChanged(pid: pid_t, title: String) {
        guard !isApplyingLayout else {
            Log.debug(Self.tag, "handleFocusChanged: applyLayout 中のためスキップ")
            return
        }

        guard let windowManager else { return }
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
            Log.info(Self.tag, "  マスターウィンドウが閉じられたため、新しいマスターに設定: \(masterWindowID ?? "nil")")
        }
        scheduleLayoutUpdate()
    }

    @MainActor
    private func handleMouseClick(event: NSEvent) {
        let flags = event.modifierFlags
        let isCtrlShiftPressed = flags.contains(.control) && flags.contains(.shift)
        guard isCtrlShiftPressed else { return }

        let mouseLocation = NSEvent.mouseLocation
        let axPoint = screenManager.appKitToAX(mouseLocation)
        
        Log.info(Self.tag, "handleMouseClick: Control+Shiftクリック検知 mouseLocation=\(mouseLocation), axPoint=\(axPoint)")
        
        guard let axWindow = AccessibilityHelper.getWindow(at: axPoint) else {
            Log.debug(Self.tag, "  マウス位置にウィンドウ要素が見つかりません")
            return
        }
        
        guard let clickWindowID = AccessibilityHelper.getWindowID(of: axWindow) else {
            Log.debug(Self.tag, "  取得したウィンドウ要素 of CGWindowID を取得できません")
            return
        }
        
        var pid: pid_t = 0
        AXUIElementGetPid(axWindow, &pid)
        
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
            if masterWindowID == nil {
                setMasterWindowID(id)
            }
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
                        windowManager.setTilingInProgress(false)
                    }
                    floatModeOriginalFrames.removeValue(forKey: window.id)
                }
            }
        }
        
        // 2. 現在の王冠ウィンドウ（masterWindowID）を中央に特定%で表示する
        if let masterID = masterWindowID,
           let masterWindow = allWindows.first(where: { $0.id == masterID }),
           let axWindow = AccessibilityHelper.findWindow(for: masterWindow.pid, windowID: masterWindow.windowID, title: masterWindow.title) {
            
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
            
            // 特定% (幅・高さともに ratio 割合にする)
            let ratio = AppSettings.shared.mainWidthRatio
            let targetWidth = visibleFrame.width * ratio
            let targetHeight = visibleFrame.height * ratio
            let targetX = visibleFrame.minX + (visibleFrame.width - targetWidth) / 2
            let targetY = visibleFrame.minY + (visibleFrame.height - targetHeight) / 2
            
            let targetFrame = CGRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
            Log.info(Self.tag, "[FloatMode] 王冠ウィンドウを中央に配置: \(masterWindow.appName) -> \(targetFrame)")
            
            windowManager.setTilingInProgress(true)
            AccessibilityHelper.setFrame(targetFrame, to: axWindow)
            windowManager.setTilingInProgress(false)
            
            // アクティブにする
            AccessibilityHelper.focus(window: axWindow)
        }
    }

    func applyLayout() {
        isApplyingLayout = true
        guard let windowManager else { return }
        
        if windowManager.currentMode == .float {
            applyFloatLayout()
            isApplyingLayout = false
            return
        }
        
        // staged も含めた全ウィンドウを対象とする（ホバーバーの表示順と同期するため）
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows

        // マスターウィンドウが格納されている、消失している、あるいは未設定の場合の自動補正
        if let currentMasterID = masterWindowID {
            let isStaged = windowManager.stagedWindows.contains(where: { $0.id == currentMasterID })
            let exists = allWindows.contains(where: { $0.id == currentMasterID })
            if isStaged || !exists {
                let remaining = windowManager.managedWindows.filter { $0.state != .staged }
                if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                    Log.info(Self.tag, "マスターウィンドウが格納または消失したため、新マスターに自動移譲: \(nextMaster.appName) (id=\(nextMaster.id))")
                    setMasterWindowID(nextMaster.id)
                } else {
                    setMasterWindowID(nil)
                }
            }
        } else if !allWindows.isEmpty {
            let remaining = windowManager.managedWindows.filter { $0.state != .staged }
            if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                Log.info(Self.tag, "マスターウィンドウが未設定のため、新マスターに自動設定: \(nextMaster.appName) (id=\(nextMaster.id))")
                setMasterWindowID(nextMaster.id)
            }
        }

        Log.info(Self.tag, "applyLayout() 開始 focusedID=\(focusedWindowID ?? "nil") masterID=\(masterWindowID ?? "nil") 対象=\(allWindows.count)枚")

        guard !allWindows.isEmpty else {
            Log.warn(Self.tag, "applyLayout: 対象ウィンドウなし")
            isApplyingLayout = false
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
            
            let idx = screenIndex(for: currentFrame, in: screens)
            screenGroups[idx].append(window)
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
            let sides = Array(sortedGroup.dropFirst(mainCount))

            if monitorStyle == .absoluteSplit2 || monitorStyle == .absoluteSplit3 {
                // mains (上位2/3個) の中で staged になっているものを unstage する
                for window in mains {
                    if window.state == .staged {
                        Log.info(Self.tag, "完全分割の上位に入るため復帰: \"\(window.appName) - \(window.title)\"")
                        windowManager.unstageWindow(window)
                        hasStateChanged = true
                    }
                }
                // sides (上位からあぶれたもの) の中で staged でないものを stage (Dock) する
                for window in sides {
                    if window.state != .staged {
                        Log.info(Self.tag, "完全分割の上位から外れたため格納: \"\(window.appName) - \(window.title)\"")
                        windowManager.stageWindow(window, forceDock: true)
                        hasStateChanged = true
                    }
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
            isApplyingLayout = false
            return
        }

        // フェーズ2: ウィンドウの物理配置適用
        // タイリング中フラグ
        windowManager.setTilingInProgress(true)

        // フォーカスするウィンドウの AXUIElement
        var axWindowToFocus: AXUIElement? = nil
        var appliedFrames: [(id: String, frame: CGRect)] = []
        var appliedIdealSizes: [(id: String, size: CGSize)] = []

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

            for (i, window) in activeGroup.enumerated() {
                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) else {
                    Log.error(Self.tag, "    ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\(window.title)")
                    continue
                }

                if AccessibilityHelper.isMinimized(axWindow) {
                    Log.info(Self.tag, "    → 最小化を解除: \"\(window.appName)\"")
                    AccessibilityHelper.restore(window: axWindow)
                }

                let targetFrame: CGRect
                let role: String
                var isLeftWindow = false
                var isRightWindow = false

                let isMain = i < mainCount

                if isMain {
                    // MAIN ウィンドウは常に理想通りのサイズで配置
                    targetFrame = idealFrames[min(i, idealFrames.count - 1)]
                    role = "MAIN_\(i)"
                } else {
                    // SIDE ウィンドウ
                    let idealFrame = idealFrames[min(i, idealFrames.count - 1)]

                    // 前回の実際の高さが、前回の理想の高さより大きい場合、それをこのウィンドウの最小高さ制限とみなす
                    let lastH = window.frame.height
                    let minH: CGFloat
                    if window.isResizeFailed {
                        minH = idealFrame.height
                    } else if let lastIdeal = window.lastIdealSize, lastH > lastIdeal.height + 5 {
                        minH = lastH
                    } else {
                        minH = idealFrame.height
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

                    if remainingH >= minSideWindowHeight && currentY + minSideWindowHeight <= screenAXFrame.minY + screenAXFrame.height - gap.outer {
                        let targetH = min(minH, remainingH)
                        targetFrame = CGRect(
                            x: isLeft ? (actualLeftX ?? idealFrame.origin.x) : (actualRightX ?? idealFrame.origin.x),
                            y: currentY,
                            width: isLeft ? (actualLeftW ?? idealFrame.width) : (actualRightW ?? idealFrame.width),
                            height: targetH
                        )
                        role = isLeft ? "SIDE_L[\(i)]" : "SIDE_R[\(i)]"
                        if isLeft {
                            isLeftWindow = true
                        } else {
                            isRightWindow = true
                        }
                    } else {
                        // 収まりきらない場合は画面外（十分に離れた左側）に格納
                        targetFrame = CGRect(
                            x: -4000,
                            y: screenAXFrame.minY + CGFloat(i) * 10,
                            width: 200,
                            height: 200
                        )
                        role = "OFFSCREEN[\(i)]"
                    }
                }

                Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" → \(targetFrame)")
                let success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
                windowManager.setResizeFailed(id: window.id, failed: !success)

                // 実際の配置後のフレームを取得して追跡
                let actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame

                // 配置後のフレームを記録 (実際の配置フレームを使うことで、stale なキャッシュを防ぐ)
                appliedFrames.append((id: window.id, frame: actualFrame))

                // 今回指定した理想サイズを記録
                let idealSz = idealFrames[min(i, idealFrames.count - 1)].size
                appliedIdealSizes.append((id: window.id, size: idealSz))

                if i == 0 {
                    // 左側サイドバーの幅決定（通常のメイン、または2分割メインの左側）
                    let leftX = screenAXFrame.minX + gap.outer
                    let leftMaxX = targetFrame.minX - gap.inner
                    actualLeftX = leftX
                    actualLeftW = max(100, leftMaxX - leftX)
                    
                    // splitCentered, absoluteSplit2, absoluteSplit3 以外の場合は、i == 0 の右端が右サイドバーの左端になる
                    if monitorStyle != .splitCentered && monitorStyle != .absoluteSplit2 && monitorStyle != .absoluteSplit3 {
                        let rightX = targetFrame.maxX + gap.inner
                        let screenMaxX = screenAXFrame.minX + screenAXFrame.width - gap.outer
                        actualRightX = rightX
                        actualRightW = max(100, screenMaxX - rightX)
                    }
                } else if i == 1 && monitorStyle == .splitCentered {
                    // splitCentered の場合のみ、i == 1（中央メイン右側）の右端が右サイドバーの左端になる
                    let rightX = targetFrame.maxX + gap.inner
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

        // focus() 後の OS によるウィンドウ微小移動通知を吸収するため少し遅らせて false に戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.windowManager?.syncActualFrames() // 物理的な配置完了後のリアル座標で最終同期！
            self.windowManager?.setTilingInProgress(false)
            self.isApplyingLayout = false
            Log.debug(Self.tag, "setTilingInProgress(false) / isApplyingLayout=false 完了")
        }

        Log.info(Self.tag, "applyLayout() 完了")
    }

    // MARK: - Private

    private func screenIndex(for axFrame: CGRect, in screens: [NSScreen]) -> Int {
        let appKitFrame = screenManager.axToAppKit(axFrame)
        var bestIndex = 0
        var bestArea: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let intersection = screen.frame.intersection(appKitFrame)
            let area = intersection.width > 0 && intersection.height > 0
                ? intersection.width * intersection.height : 0
            if area > bestArea { bestArea = area; bestIndex = i }
        }

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

        return bestIndex
    }
}
