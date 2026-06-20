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
    /// applyLayout() 実行中フラグ
    /// この間は didActivateApplicationNotification による focusedWindowID 更新を抑制する
    private var isApplyingLayout: Bool = false

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
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Log.info(Self.tag, "didActivateApplication: \(app.localizedName ?? "?")")
            Task { @MainActor in
                // applyLayout() 実行中は通知による上書きを抑制
                guard !self.isApplyingLayout else {
                    Log.debug(Self.tag, "didActivateApplication: applyLayout 中のため スキップ")
                    return
                }
                self.updateFocusedWindow(runningApp: app)
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
        Log.info(Self.tag, "  現在の focusedWindowID=\(focusedWindowID ?? "nil")")
        Log.info(Self.tag, "  isApplyingLayout=\(isApplyingLayout)")

        // managedWindows の状態も記録
        if let windowManager {
            let windows = windowManager.managedWindows
            Log.info(Self.tag, "  managedWindows(\(windows.count)件):")
            for (i, w) in windows.enumerated() {
                let isTarget = w.id == windowID ? " ← ターゲット" : ""
                let isCurrent = w.id == focusedWindowID ? " ← 現在フォーカス" : ""
                Log.info(Self.tag, "    [\(i)] \"\(w.appName) - \(w.title)\" id=\(w.id)\(isTarget)\(isCurrent)")
            }
        }

        guard focusedWindowID != windowID else {
            Log.debug(Self.tag, "switchMainWindow: 変更なし (already \(windowID))")
            return
        }
        Log.info(Self.tag, "  切り替え: \(focusedWindowID ?? "nil") → \(windowID)")
        setFocusedWindowID(windowID)
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
                scheduleLayoutUpdate()
            }
        }
    }

    // MARK: - Private Helpers

    /// focusedWindowID を更新し WindowManager の @Published 値にも反映させる
    private func setFocusedWindowID(_ id: String?) {
        focusedWindowID = id
        windowManager?.updateFocusedWindowID(id)
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
        isApplyingLayout = true
        guard let windowManager else { return }
        let windows = windowManager.managedWindows.filter { $0.state != .staged }

        Log.info(Self.tag, "applyLayout() 開始 focusedID=\(focusedWindowID ?? "nil") 対象=\(windows.count)枚")

        guard !windows.isEmpty else {
            Log.warn(Self.tag, "applyLayout: 対象ウィンドウなし")
            return
        }

        // フォーカスウィンドウを先頭に並び替え
        var ordered = windows
        var focusedWindow: ManagedWindow? = nil
        if let focusedID = focusedWindowID,
           let idx = ordered.firstIndex(where: { $0.id == focusedID }) {
            let focused = ordered.remove(at: idx)
            ordered.insert(focused, at: 0)
            focusedWindow = focused
            Log.debug(Self.tag, "  先頭(フォーカス): \"\(focused.appName) - \(focused.title)\"")
        } else {
            Log.warn(Self.tag, "  focusedID が managedWindows に存在しない → 先頭をそのまま使用")
            focusedWindow = ordered.first
        }

        // スクリーン別グループ化
        let screens = NSScreen.screens
        var screenGroups: [[ManagedWindow]] = Array(repeating: [], count: max(screens.count, 1))
        for window in ordered {
            let idx = screenIndex(for: window.frame, in: screens)
            screenGroups[idx].append(window)
        }

        // タイリング中フラグ（全スクリーン分の処理全体を囲む）
        windowManager.setTilingInProgress(true)

        // フォーカスするウィンドウの AXUIElement（配置後に1回だけ focus() する）
        var axWindowToFocus: AXUIElement? = nil
        // 配置後のフレームを記録（ManagedWindow.frame 更新用）
        var appliedFrames: [(id: String, frame: CGRect)] = []

        for (si, group) in screenGroups.enumerated() {
            guard !group.isEmpty else { continue }
            let screen = screens[si]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            Log.info(Self.tag, "  Screen[\(si)] \(group.count)枚 AXFrame=\(screenAXFrame)")

            let frames = layout.calculateFrames(windowCount: group.count, screenFrame: screenAXFrame)

            for (i, window) in group.enumerated() {
                let targetFrame: CGRect
                let role: String
                if i < frames.count {
                    targetFrame = frames[i]
                    role = i == 0 ? "MAIN" : "SIDE[\(i)]"
                } else {
                    // 表示制限を超えるウィンドウは画面外（スクリーンの直下）に格納
                    // これにより最小化せずに非表示にでき、managedWindows に残り続けます
                    targetFrame = CGRect(
                        x: screenAXFrame.minX + 100,
                        y: screenAXFrame.minY + screenAXFrame.height + 500,
                        width: 200,
                        height: 200
                    )
                    role = "OFFSCREEN[\(i)]"
                }

                Log.info(Self.tag, "    \(role) \"\(window.appName) - \(window.title)\" → \(targetFrame)")

                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) else {
                    Log.error(Self.tag, "    ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\(window.title)")
                    continue
                }

                // 必要なら最小化を解除（ユーザーが手動で最小化していた場合などに備えて）
                if AccessibilityHelper.isMinimized(axWindow) {
                    Log.info(Self.tag, "    → 最小化を解除: \"\(window.appName)\"")
                    AccessibilityHelper.restore(window: axWindow)
                }

                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)

                // 配置後、実際のフレームを AX から再取得して記録（サイズ制限等を考慮するため）
                let realFrame = AccessibilityHelper.getFrame(of: axWindow) ?? targetFrame
                appliedFrames.append((id: window.id, frame: realFrame))

                // フォーカスウィンドウの AX を記録（まだ focus() しない）
                if window.id == focusedWindow?.id {
                    axWindowToFocus = axWindow
                    Log.debug(Self.tag, "    → focus 予定: \"\(window.appName)\"")
                }
            }
        }

        // ManagedWindow.frame を配置後の値で更新（次回 screenIndex が stale フレームを使わないように）
        windowManager.updateFrames(appliedFrames)
        Log.debug(Self.tag, "  ManagedWindow.frame 更新: \(appliedFrames.count)件")

        // 全ウィンドウ配置完了後に、フォーカスウィンドウだけ focus() する
        if let axWindowToFocus {
            Log.info(Self.tag, "  focus() 実行: \"\(focusedWindow?.appName ?? "?")\"")
            AccessibilityHelper.focus(window: axWindowToFocus)
        }

        // focus() 後の OS によるウィンドウ微小移動通知を吸収するため少し遅らせて false に戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.windowManager?.setTilingInProgress(false)
            self?.isApplyingLayout = false
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
