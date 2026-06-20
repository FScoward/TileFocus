import Foundation
import AppKit

/// Focus Mode のロジックを担当するコントローラー
///
/// 動作:
/// 1. アクティブ化時: フロントウィンドウを中央大きく、他をサイドバーに配置
/// 2. アプリ切り替え時 (NSWorkspace 通知): 自動的にレイアウトを更新
/// 3. ⌃⌘M: 手動でメインウィンドウを切り替え
@MainActor
final class FocusModeController {

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = FocusLayout()

    // MARK: - State

    /// フォーカス中のウィンドウ ID（メインウィンドウ）
    private var focusedWindowID: String?

    /// NSWorkspace の通知 token
    private var workspaceObservers: [NSObjectProtocol] = []

    /// デバウンス用 WorkItem（連続したレイアウト更新をまとめる）
    private var updateWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func activate() {
        // 現在フォーカスされているウィンドウをメインに設定
        updateFocusedWindow()
        applyLayout()

        // アプリ切り替えを監視 → 自動的にレイアウト更新
        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateFocusedWindow()
                self.scheduleLayoutUpdate()
            }
        }

        workspaceObservers = [activateToken]
        print("[FocusModeController] アクティブ化 - 監視開始")
    }

    func deactivate() {
        updateWorkItem?.cancel()
        updateWorkItem = nil

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []
        focusedWindowID = nil
        print("[FocusModeController] 非アクティブ化")
    }

    // MARK: - Focus Control

    /// フロントアプリのメインウィンドウを focused として設定
    private func updateFocusedWindow() {
        guard let windowManager else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        // TileFocus 自身がフロントになった場合は無視
        if frontApp.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }

        let pid = frontApp.processIdentifier

        // kAXMainAttribute == true のウィンドウを探す
        let axWindows = AccessibilityHelper.getWindows(for: pid)
        let mainAX = axWindows.first { AccessibilityHelper.isMainWindow($0) } ?? axWindows.first

        let mainTitle = mainAX.flatMap { AccessibilityHelper.getTitle(of: $0) } ?? ""

        // managedWindows 内で対応するウィンドウを探す
        if let match = windowManager.managedWindows.first(where: {
            $0.pid == pid && ($0.title == mainTitle || mainTitle.isEmpty)
        }) {
            if match.id != focusedWindowID {
                focusedWindowID = match.id
                print("[FocusModeController] フォーカス変更: \(match.appName) - \(match.title)")
            }
        } else if let first = windowManager.managedWindows.first(where: { $0.pid == pid }) {
            if first.id != focusedWindowID {
                focusedWindowID = first.id
                print("[FocusModeController] フォーカス変更(PIDマッチ): \(first.appName)")
            }
        }
    }

    /// メインウィンドウを手動で切り替える（⌌⌘M 連携）
    func switchMainWindow(to windowID: String) {
        guard focusedWindowID != windowID else { return }
        focusedWindowID = windowID
        applyLayout()
    }

    // MARK: - Layout Application

    /// デバウンス付きレイアウト更新（アプリ切り替え通知の連続発火対策）
    func scheduleLayoutUpdate(debounce: TimeInterval = 0.1) {
        updateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyLayout()
        }
        updateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// フォーカスレイアウトを適用
    func applyLayout() {
        guard let windowManager else { return }
        let windows = windowManager.managedWindows.filter { $0.state != .staged }
        guard !windows.isEmpty else { return }

        // フォーカスウィンドウを先頭に並び替え
        var ordered = windows
        if let focusedID = focusedWindowID,
           let idx = ordered.firstIndex(where: { $0.id == focusedID }) {
            let focused = ordered.remove(at: idx)
            ordered.insert(focused, at: 0)
        }

        // スクリーン別にグループ化
        let screens = NSScreen.screens
        var screenGroups: [[ManagedWindow]] = Array(repeating: [], count: max(screens.count, 1))
        for window in ordered {
            let idx = screenIndex(for: window.frame, in: screens)
            screenGroups[idx].append(window)
        }

        // タイリング中フラグ（AX 通知ループ防止）
        windowManager.setTilingInProgress(true)
        defer { windowManager.setTilingInProgress(false) }

        for (si, group) in screenGroups.enumerated() {
            guard !group.isEmpty else { continue }
            let screen = screens[si]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            let frames = layout.calculateFrames(windowCount: group.count, screenFrame: screenAXFrame)

            for (i, window) in group.enumerated() {
                guard i < frames.count else { break }
                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, title: window.title) else {
                    continue
                }
                let targetFrame = frames[i]
                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)

                // メインウィンドウ（index==0）にフォーカスを当てる
                if i == 0 {
                    AccessibilityHelper.focus(window: axWindow)
                }
            }
        }

        print("[FocusModeController] レイアウト適用: \(ordered.count) ウィンドウ, focus=\(focusedWindowID ?? "none")")
    }

    // MARK: - Private

    /// AX フレームが最もよく含まれるスクリーンのインデックスを返す
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
        return bestIndex
    }
}
