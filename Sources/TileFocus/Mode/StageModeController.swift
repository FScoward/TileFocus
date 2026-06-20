import Foundation
import AppKit

/// Stage Mode のロジックを担当するコントローラー
@MainActor
final class StageModeController {

    nonisolated private static let tag = "StageModeController"

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = StageLayout()
    private let sidebarController = StageSidebarController()

    // MARK: - State

    private var activeWindowID: String?
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
        
        // サイドバーを表示
        if let windowManager {
            sidebarController.show(windowManager: windowManager)
        }

        // 初期状態でフォーカスされているウィンドウを特定し、それ以外を格納する
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
        
        activeWindowID = nil
        Log.info(Self.tag, "deactivate() 完了")
    }

    // MARK: - Stage State Management

    /// 初期化時にフォーカスされているウィンドウをメインとし、それ以外をすべて格納（stage）する
    private func initializeStageState() {
        guard let windowManager else { return }
        
        // 現在フォーカスされているアプリ
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let frontPid = frontApp.processIdentifier
        
        let managed = windowManager.managedWindows
        
        // フロントのウィンドウをメインとして決定
        let mainAX = AccessibilityHelper.getWindows(for: frontPid)
            .first { AccessibilityHelper.isMainWindow($0) }
        let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""
        
        var targetMainWindow: ManagedWindow? = nil
        if let match = managed.first(where: { $0.pid == frontPid && ($0.title == mainTitle || mainTitle.isEmpty) }) {
            targetMainWindow = match
        } else if let first = managed.first(where: { $0.pid == frontPid }) {
            targetMainWindow = first
        } else {
            targetMainWindow = managed.first
        }
        
        guard let main = targetMainWindow else { return }
        activeWindowID = main.id
        
        // メイン以外をすべて格納する
        let toStage = managed.filter { $0.id != main.id }
        for w in toStage {
            windowManager.stageWindow(w)
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

        // managedWindows または stagedWindows から対応するウィンドウを探す
        let allWindows = windowManager.managedWindows + windowManager.stagedWindows
        guard let match = allWindows.first(where: {
            $0.pid == pid && ($0.title == mainTitle || mainTitle.isEmpty)
        }) ?? allWindows.first(where: { $0.pid == pid }) else {
            return
        }

        switchActiveWindow(to: match.id)
    }

    /// 指定したウィンドウをメインウィンドウに切り替える（自動で古いものを格納）
    func switchActiveWindow(to windowID: String) {
        guard let windowManager else { return }
        guard activeWindowID != windowID else { return }

        Log.info(Self.tag, "switchActiveWindow(to: \(windowID)) - 現在のメイン: \(activeWindowID ?? "nil")")

        // 1. 現在のメインウィンドウを格納（もし現在画面上にあれば）
        if let currentActiveID = activeWindowID,
           let currentActive = windowManager.managedWindows.first(where: { $0.id == currentActiveID }) {
            windowManager.stageWindow(currentActive)
        }

        // 2. 新しいウィンドウを復帰
        if let target = windowManager.stagedWindows.first(where: { $0.id == windowID }) {
            windowManager.unstageWindow(target)
        }

        activeWindowID = windowID
        applyLayout()
    }

    /// ウィンドウが閉じられた場合の処理
    func handleWindowClosed(id: String) {
        guard let windowManager else { return }
        if activeWindowID == id {
            // メインが閉じられたので、次にアクティブにするものを格納中リスト、または管理中リストから選ぶ
            if let next = windowManager.managedWindows.first(where: { $0.id != id }) ?? windowManager.stagedWindows.first {
                activeWindowID = next.id
                if windowManager.stagedWindows.contains(where: { $0.id == next.id }) {
                    windowManager.unstageWindow(next)
                }
            } else {
                activeWindowID = nil
            }
        }
        applyLayout()
    }

    /// 外側からフォーカス変更が通知されたとき
    func handleFocusChanged(pid: pid_t, title: String) {
        guard !isApplyingLayout else { return }
        guard let windowManager else { return }

        let all = windowManager.managedWindows + windowManager.stagedWindows
        if let match = all.first(where: { $0.pid == pid && ($0.title == title || title.isEmpty) }) ?? all.first(where: { $0.pid == pid }) {
            if match.id != activeWindowID {
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

        // 現在管理対象の（画面上にある）ウィンドウ
        let windows = windowManager.managedWindows

        guard !windows.isEmpty else {
            isApplyingLayout = false
            return
        }

        // 画面上には1つだけメインウィンドウがあるべき
        // もし複数ある場合は、activeWindowID に一致するものを先頭に持ってくる
        var ordered = windows
        if let activeID = activeWindowID,
           let idx = ordered.firstIndex(where: { $0.id == activeID }) {
            let active = ordered.remove(at: idx)
            ordered.insert(active, at: 0)
        } else if let first = ordered.first {
            activeWindowID = first.id
        }

        // メインウィンドウ以外のウィンドウは、何らかの理由で画面上に残っている場合、すべて格納する
        if ordered.count > 1 {
            let extra = Array(ordered.suffix(from: 1))
            for w in extra {
                windowManager.stageWindow(w)
            }
            ordered = [ordered[0]]
        }

        // メインウィンドウの配置処理
        windowManager.setTilingInProgress(true)

        guard let screen = NSScreen.main else {
            windowManager.setTilingInProgress(false)
            isApplyingLayout = false
            return
        }
        let screenAXFrame = screenManager.visibleFrameInAX(for: screen)

        let targetFrames = layout.calculateFrames(windowCount: ordered.count, screenFrame: screenAXFrame)
        guard !targetFrames.isEmpty else {
            windowManager.setTilingInProgress(false)
            isApplyingLayout = false
            return
        }

        let main = ordered[0]
        if let axWindow = AccessibilityHelper.findWindow(for: main.pid, windowID: main.windowID, title: main.title) {
            if AccessibilityHelper.isMinimized(axWindow) {
                AccessibilityHelper.restore(window: axWindow)
            }
            let targetFrame = targetFrames[0]
            let success = AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
            windowManager.setResizeFailed(id: main.id, failed: !success)
            
            // 実際のフレームで更新
            let actualFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
            windowManager.updateFrames([(id: main.id, frame: actualFrame)])
            windowManager.updateLastIdealSizes([(id: main.id, size: targetFrame.size)])

            AccessibilityHelper.focus(window: axWindow)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.windowManager?.syncActualFrames()
            self.windowManager?.setTilingInProgress(false)
            self.isApplyingLayout = false
        }
    }
}
