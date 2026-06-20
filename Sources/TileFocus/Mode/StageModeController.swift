import Foundation
import AppKit

/// Stage Mode のロジックを担当するコントローラー (モニターごと個別管理対応)
@MainActor
final class StageModeController {

    nonisolated private static let tag = "StageModeController"

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = StageLayout()
    private let sidebarController = StageSidebarController()

    // MARK: - State

    /// モニターごとのアクティブウィンドウID
    private var activeWindowIDs: [NSScreen: String] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var updateWorkItem: DispatchWorkItem?
    private var isApplyingLayout: Bool = false

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func activate() {
        Log.info(Self.tag, "activate() 開始")
        
        // 全モニターにサイドバーを表示
        if let windowManager {
            sidebarController.show(windowManager: windowManager)
        }

        // 初期状態でモニターごとにフォーカスされているウィンドウを特定し、それ以外を格納する
        initializeStageState()
        applyLayout()

        // アプリケーションのアクティブ化通知を監視
        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Log.info(Self.tag, "didActivateApplication: \(app.localizedName ?? "?")")
            Task { @MainActor in
                guard !self.isApplyingLayout else { return }
                self.handleAppActivated(app)
            }
        }

        workspaceObservers = [activateToken]
        Log.info(Self.tag, "activate() 完了")
    }

    func deactivate() {
        Log.info(Self.tag, "deactivate() 開始")
        updateWorkItem?.cancel()
        updateWorkItem = nil

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []
        
        // サイドバーを非表示にする
        sidebarController.hide()
        
        // すべてのウィンドウを画面上に復帰させる
        if let windowManager {
            windowManager.unstageAllWindows()
        }
        
        activeWindowIDs.removeAll()
        Log.info(Self.tag, "deactivate() 完了")
    }

    // MARK: - Stage State Management

    /// 各スクリーン上で最初のアクティブウィンドウを特定し、それ以外を格納（stage）する
    private func initializeStageState() {
        guard let windowManager else { return }
        let managed = windowManager.managedWindows
        
        // スクリーン別にウィンドウをグループ化
        var screenGroups: [NSScreen: [ManagedWindow]] = [:]
        for screen in NSScreen.screens {
            screenGroups[screen] = []
        }
        
        for w in managed {
            let screen = screenManager.screen(containingAXFrame: w.frame)
            screenGroups[screen, default: []].append(w)
        }
        
        // 現在フォーカスされているアプリ
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        for (screen, windows) in screenGroups {
            guard !windows.isEmpty else { continue }
            
            // そのスクリーン上でアクティブにするウィンドウを決定する
            var targetMainWindow: ManagedWindow? = nil
            
            if let pid = frontPid {
                let mainAX = AccessibilityHelper.getWindows(for: pid)
                    .first { AccessibilityHelper.isMainWindow($0) }
                let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""
                
                if let match = windows.first(where: { $0.pid == pid && ($0.title == mainTitle || mainTitle.isEmpty) }) {
                    targetMainWindow = match
                } else if let first = windows.first(where: { $0.pid == pid }) {
                    targetMainWindow = first
                }
            }
            
            if targetMainWindow == nil {
                targetMainWindow = windows.first
            }
            
            guard let main = targetMainWindow else { continue }
            activeWindowIDs[screen] = main.id
            Log.info(Self.tag, "スクリーン[\(screen.localizedName)] の初期メイン: \(main.appName) (id=\(main.id))")
            
            // メイン以外をすべて格納する
            let toStage = windows.filter { $0.id != main.id }
            for w in toStage {
                windowManager.stageWindow(w)
            }
        }
    }

    /// アプリがアクティブになった際の処理（自動切り替え）
    private func handleAppActivated(_ app: NSRunningApplication) {
        guard let windowManager else { return }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return } // 自プロセスは無視

        let pid = app.processIdentifier
        let axWindows = AccessibilityHelper.getWindows(for: pid)
        let mainAX = axWindows.first { AccessibilityHelper.isMainWindow($0) } ?? axWindows.first
        let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""

        // 全ウィンドウリスト（管理中＋格納中）から対象を特定
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows
        guard let match = allWindows.first(where: {
            $0.pid == pid && ($0.title == mainTitle || mainTitle.isEmpty)
        }) ?? allWindows.first(where: { $0.pid == pid }) else {
            return
        }

        switchActiveWindow(to: match.id)
    }

    /// 指定したウィンドウをメインウィンドウに切り替える（同じモニターの古いメインは自動格納）
    func switchActiveWindow(to windowID: String) {
        guard let windowManager else { return }

        // 切り替え対象ウィンドウの元のフレーム（格納前）から所属スクリーンを特定
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows
        guard let target = allWindows.first(where: { $0.id == windowID }) else { return }
        let targetFrame = target.frameBeforeStaging ?? target.frame
        let screen = screenManager.screen(containingAXFrame: targetFrame)

        let currentActiveID = activeWindowIDs[screen]
        guard currentActiveID != windowID else { return }

        Log.info(Self.tag, "スクリーン[\(screen.localizedName)] 切り替え: \(currentActiveID ?? "nil") -> \(windowID)")

        // 1. 現在そのスクリーンでアクティブなウィンドウを格納
        if let activeID = currentActiveID,
           let currentActive = windowManager.managedWindows.first(where: { $0.id == activeID }) {
            windowManager.stageWindow(currentActive)
        }

        // 2. 新しいウィンドウを復帰
        if let stagedTarget = windowManager.stagedWindows.first(where: { $0.id == windowID }) {
            windowManager.unstageWindow(stagedTarget)
        }

        activeWindowIDs[screen] = windowID
        applyLayout()
    }

    /// ウィンドウが閉じられた場合の処理
    func handleWindowClosed(id: String) {
        guard let windowManager else { return }
        
        // どのスクリーンで閉じられたかを特定
        guard let screen = activeWindowIDs.first(where: { $0.value == id })?.key else {
            applyLayout()
            return
        }
        
        // 代わりのウィンドウを探す
        let allRemaining = (windowManager.managedWindows + windowManager.stagedWindows).filter { $0.id != id }
        let screenWindows = allRemaining.filter { w in
            let frame = w.frameBeforeStaging ?? w.frame
            return screenManager.screen(containingAXFrame: frame) == screen
        }
        
        if let next = screenWindows.first {
            activeWindowIDs[screen] = next.id
            if windowManager.stagedWindows.contains(where: { $0.id == next.id }) {
                windowManager.unstageWindow(next)
            }
        } else {
            activeWindowIDs.removeValue(forKey: screen)
        }
        
        applyLayout()
    }

    /// 外側からフォーカス変更が通知されたとき
    func handleFocusChanged(pid: pid_t, title: String) {
        guard !isApplyingLayout else { return }
        guard let windowManager else { return }

        let all = windowManager.managedWindows + windowManager.stagedWindows
        if let match = all.first(where: { $0.pid == pid && ($0.title == title || title.isEmpty) }) ?? all.first(where: { $0.pid == pid }) {
            let targetFrame = match.frameBeforeStaging ?? match.frame
            let screen = screenManager.screen(containingAXFrame: targetFrame)
            if match.id != activeWindowIDs[screen] {
                switchActiveWindow(to: match.id)
            }
        }
    }

    // MARK: - Layout Application

    func scheduleLayoutUpdate() {
        updateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyLayout()
        }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func applyLayout() {
        isApplyingLayout = true
        guard let windowManager else { return }

        // 現在管理対象のウィンドウ
        let windows = windowManager.managedWindows
        guard !windows.isEmpty else {
            isApplyingLayout = false
            return
        }

        // スクリーン別に、画面上に残っているウィンドウをグループ化
        var screenGroups: [NSScreen: [ManagedWindow]] = [:]
        for screen in NSScreen.screens {
            screenGroups[screen] = []
        }
        for w in windows {
            let screen = screenManager.screen(containingAXFrame: w.frame)
            screenGroups[screen, default: []].append(w)
        }

        windowManager.setTilingInProgress(true)

        // 配置指示用のキャッシュを蓄積
        var appliedFrames: [(id: String, frame: CGRect)] = []
        var appliedIdealSizes: [(id: String, size: CGSize)] = []

        for (screen, group) in screenGroups {
            guard !group.isEmpty else { continue }
            
            var activeID = activeWindowIDs[screen]
            
            // アクティブウィンドウIDが設定されていなければ、グループの最初を割り当てる
            if activeID == nil || !group.contains(where: { $0.id == activeID }) {
                activeID = group.first?.id
                activeWindowIDs[screen] = activeID
            }
            
            var ordered = group
            if let aID = activeID, let idx = ordered.firstIndex(where: { $0.id == aID }) {
                let active = ordered.remove(at: idx)
                ordered.insert(active, at: 0)
            }
            
            // 画面上に残っているアクティブ外のウィンドウを格納する
            if ordered.count > 1 {
                let extra = Array(ordered.suffix(from: 1))
                for w in extra {
                    windowManager.stageWindow(w)
                }
                ordered = [ordered[0]]
            }
            
            // レイアウトの適用
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            let targetFrames = layout.calculateFrames(windowCount: ordered.count, screenFrame: screenAXFrame)
            guard !targetFrames.isEmpty else { continue }
            
            let main = ordered[0]
            if let axWindow = AccessibilityHelper.findWindow(for: main.pid, windowID: main.windowID, title: main.title) {
                if AccessibilityHelper.isMinimized(axWindow) {
                    AccessibilityHelper.restore(window: axWindow)
                }
                let targetFrame = targetFrames[0]
                let success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
                windowManager.setResizeFailed(id: main.id, failed: !success)
                
                let actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
                appliedFrames.append((id: main.id, frame: actualFrame))
                appliedIdealSizes.append((id: main.id, size: targetFrame.size))
                
                // 現在フォーカスされているアプリがこのウィンドウならフォーカスする
                if let frontApp = NSWorkspace.shared.frontmostApplication,
                   frontApp.processIdentifier == main.pid {
                    AccessibilityHelper.focus(window: axWindow)
                }
            }
        }

        // キャッシュ更新
        windowManager.updateFrames(appliedFrames)
        windowManager.updateLastIdealSizes(appliedIdealSizes)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.windowManager?.syncActualFrames()
            self.windowManager?.setTilingInProgress(false)
            self.isApplyingLayout = false
        }
    }
}
