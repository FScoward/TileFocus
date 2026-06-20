import Foundation
import AppKit

/// Focus Mode のロジックを担当するコントローラー
@MainActor
final class FocusModeController {

    nonisolated private static let tag = "FocusModeController"

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = FocusLayout()

    // MARK: - State

    private var focusedWindowID: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var updateWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func activate() {
        Log.info(Self.tag, "activate() 開始")
        updateFocusedWindow()
        applyLayout()

        let activateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let appName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
            Log.info(Self.tag, "didActivateApplication: \(appName)")
            Task { @MainActor in
                self.updateFocusedWindow()
                self.scheduleLayoutUpdate()
            }
        }

        workspaceObservers = [activateToken]
        Log.info(Self.tag, "activate() 完了 - NSWorkspace 監視開始")
    }

    func deactivate() {
        Log.info(Self.tag, "deactivate()")
        updateWorkItem?.cancel()
        updateWorkItem = nil

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []
        focusedWindowID = nil
    }

    // MARK: - Focus Control

    private func updateFocusedWindow() {
        guard let windowManager else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
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
                focusedWindowID = match.id
            } else {
                Log.debug(Self.tag, "  フォーカス変更なし (already \(match.id))")
            }
        } else if let first = managedWindows.first(where: { $0.pid == pid }) {
            if first.id != focusedWindowID {
                Log.warn(Self.tag, "  タイトル不一致 → PID マッチで \"\(first.appName) - \(first.title)\"")
                focusedWindowID = first.id
            }
        } else {
            Log.warn(Self.tag, "  managedWindowsに \(appName)(pid=\(pid)) が存在しない → refreshWindowList を実行")
            windowManager.refreshWindowList()
            // リフレッシュ後に再度検索
            if let match = windowManager.managedWindows.first(where: { $0.pid == pid }) {
                focusedWindowID = match.id
                Log.info(Self.tag, "  リフレッシュ後マッチ: \"\(match.appName)\"")
            }
        }
    }

    func switchMainWindow(to windowID: String) {
        guard focusedWindowID != windowID else {
            Log.debug(Self.tag, "switchMainWindow: 変更なし (already \(windowID))")
            return
        }
        Log.info(Self.tag, "switchMainWindow: \(focusedWindowID ?? "nil") → \(windowID)")
        focusedWindowID = windowID
        applyLayout()
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

    func applyLayout() {
        guard let windowManager else { return }
        let windows = windowManager.managedWindows.filter { $0.state != .staged }

        Log.info(Self.tag, "applyLayout() 開始 focusedID=\(focusedWindowID ?? "nil") 対象=\(windows.count)枚")

        guard !windows.isEmpty else {
            Log.warn(Self.tag, "applyLayout: 対象ウィンドウなし")
            return
        }

        // フォーカスウィンドウを先頭に並び替え
        var ordered = windows
        if let focusedID = focusedWindowID,
           let idx = ordered.firstIndex(where: { $0.id == focusedID }) {
            let focused = ordered.remove(at: idx)
            ordered.insert(focused, at: 0)
            Log.debug(Self.tag, "  先頭: \"\(focused.appName) - \(focused.title)\"")
        } else {
            Log.warn(Self.tag, "  focusedID が managedWindows に存在しない → 先頭をそのまま使用")
        }

        // スクリーン別グループ化
        let screens = NSScreen.screens
        var screenGroups: [[ManagedWindow]] = Array(repeating: [], count: max(screens.count, 1))
        for window in ordered {
            let idx = screenIndex(for: window.frame, in: screens)
            screenGroups[idx].append(window)
        }

        for (si, group) in screenGroups.enumerated() {
            guard !group.isEmpty else { continue }
            let screen = screens[si]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            Log.info(Self.tag, "  Screen[\(si)] \(group.count)枚 AXFrame=\(screenAXFrame)")

            let frames = layout.calculateFrames(windowCount: group.count, screenFrame: screenAXFrame)

            // タイリング中フラグ
            windowManager.setTilingInProgress(true)

            for (i, window) in group.enumerated() {
                guard i < frames.count else { break }
                let targetFrame = frames[i]
                let role = i == 0 ? "MAIN" : "SIDE[\(i)]"
                Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" → \(targetFrame)")

                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, title: window.title) else {
                    Log.error(Self.tag, "    ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\(window.title)")
                    continue
                }
                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)

                if i == 0 {
                    AccessibilityHelper.focus(window: axWindow)
                }
            }

            windowManager.setTilingInProgress(false)
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
        return bestIndex
    }
}
