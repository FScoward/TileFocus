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
    private let topBarController = StageTopBarController()

    // MARK: - State

    private var focusedWindowID: String?
    private var masterWindowID: String?
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
        
        // 上部バーを非表示にする
        topBarController.hide()
        
        // すべての格納ウィンドウを画面上に復帰させる
        if let windowManager {
            windowManager.unstageAllWindows()
        }

        focusedWindowID = nil
        masterWindowID = nil
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

        guard masterWindowID != windowID || focusedWindowID != windowID else {
            Log.debug(Self.tag, "switchMainWindow: 変更なし (already master and focused)")
            return
        }
        Log.info(Self.tag, "  マスター切り替え: \(masterWindowID ?? "nil") → \(windowID)")
        masterWindowID = windowID
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
            }
        }
    }

    /// ウィンドウが閉じられた時の処理
    func handleWindowClosed(id: String) {
        Log.info(Self.tag, "handleWindowClosed() windowID=\(id)")
        if masterWindowID == id {
            if let windowManager {
                let remaining = windowManager.managedWindows.filter { $0.id != id && $0.state != .staged }
                if let nextMaster = remaining.first(where: { $0.id == focusedWindowID }) ?? remaining.first {
                    masterWindowID = nextMaster.id
                } else {
                    masterWindowID = nil
                }
            } else {
                masterWindowID = nil
            }
            Log.info(Self.tag, "  マスターウィンドウが閉じられたため、新しいマスターに設定: \(masterWindowID ?? "nil")")
        }
        scheduleLayoutUpdate()
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

        // マスターウィンドウを先頭に並び替え
        var ordered = windows
        
        // masterWindowID が無効なら focusedWindowID をマスターとして設定
        if let masterID = masterWindowID, ordered.contains(where: { $0.id == masterID }) {
            if let idx = ordered.firstIndex(where: { $0.id == masterID }) {
                let master = ordered.remove(at: idx)
                ordered.insert(master, at: 0)
                Log.debug(Self.tag, "  先頭(マスター): \"\(master.appName) - \(master.title)\"")
            }
        } else {
            if let focusedID = focusedWindowID, let idx = ordered.firstIndex(where: { $0.id == focusedID }) {
                let focused = ordered.remove(at: idx)
                ordered.insert(focused, at: 0)
                masterWindowID = focused.id
                Log.info(Self.tag, "  マスター未指定または消失 ➔ フォーカスウィンドウをマスターに設定: \"\(focused.appName)\"")
            } else if let first = ordered.first {
                masterWindowID = first.id
                Log.warn(Self.tag, "  フォーカスなし ➔ 先頭をマスターに設定: \"\(first.appName)\"")
            }
        }

        // スクリーン別グループ化（NSScreen.screens の順序の揺らぎを防ぐため物理座標でソート）
        let screens = NSScreen.screens.sorted { s1, s2 in
            if s1.frame.origin.x != s2.frame.origin.x {
                return s1.frame.origin.x < s2.frame.origin.x
            }
            return s1.frame.origin.y > s2.frame.origin.y
        }
        var screenGroups: [[ManagedWindow]] = Array(repeating: [], count: max(screens.count, 1))
        for window in ordered {
            var currentFrame = window.frame
            if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title),
               let realFrame = AccessibilityHelper.getFrame(of: axWindow) {
                currentFrame = realFrame
            }
            let idx = screenIndex(for: currentFrame, in: screens)
            screenGroups[idx].append(window)
        }

        // タイリング中フラグ（全スクリーン分の処理全体を囲む）
        windowManager.setTilingInProgress(true)

        // フォーカスするウィンドウの AXUIElement（配置後に1回だけ focus() する）
        var axWindowToFocus: AXUIElement? = nil
        // 配置後のフレームを記録（ManagedWindow.frame 更新用）
        var appliedFrames: [(id: String, frame: CGRect)] = []
        // 配置指示した理想サイズを記録（次回のリサイズ制限チェック用）
        var appliedIdealSizes: [(id: String, size: CGSize)] = []

        let gap = layout.gap
        let minSideWindowHeight = layout.minSideWindowHeight

        for (si, group) in screenGroups.enumerated() {
            guard !group.isEmpty else { continue }
            let screen = screens[si]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            Log.info(Self.tag, "  Screen[\(si)] \(group.count)枚 AXFrame=\(screenAXFrame)")

            let idealFrames = layout.calculateFrames(windowCount: group.count, screenFrame: screenAXFrame)

            // 左右サイドバーの配置 Y 座標の追跡
            var currentLeftY = screenAXFrame.minY + gap.outer
            var currentRightY = screenAXFrame.minY + gap.outer

            // 実際のメインウィンドウの配置結果から決定される左右サイドバー of X 座標と幅
            var actualLeftX: CGFloat? = nil
            var actualLeftW: CGFloat? = nil
            var actualRightX: CGFloat? = nil
            var actualRightW: CGFloat? = nil

            for (i, window) in group.enumerated() {
                guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) else {
                    Log.error(Self.tag, "    ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\(window.title)")
                    continue
                }

                // 必要なら最小化を解除（ユーザーが手動で最小化していた場合などに備えて）
                if AccessibilityHelper.isMinimized(axWindow) {
                    Log.info(Self.tag, "    → 最小化を解除: \"\(window.appName)\"")
                    AccessibilityHelper.restore(window: axWindow)
                }

                let targetFrame: CGRect
                let role: String
                var isLeftWindow = false
                var isRightWindow = false

                if i == 0 {
                    // MAIN ウィンドウは常に理想通りのサイズで配置
                    targetFrame = idealFrames[0]
                    role = "MAIN"
                } else {
                    // SIDE ウィンドウ
                    let idealFrame = idealFrames[min(i, idealFrames.count - 1)]
                    
                    // 前回の実際の高さが、前回の理想の高さより大きい場合、それをこのウィンドウの最小高さ制限とみなす
                    // （ただし画面外退避されていた時の 200px は除外する。またリサイズ失敗したウィンドウも除外する）
                    let lastH = window.frame.height
                    let minH: CGFloat
                    if window.isResizeFailed {
                        minH = idealFrame.height
                    } else if let lastIdeal = window.lastIdealSize, lastH > lastIdeal.height + 5 {
                        minH = lastH
                    } else {
                        minH = idealFrame.height
                    }
                    
                    let isLeft = (i % 2 == 1)
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
                let idealSz = (i == 0) ? idealFrames[0].size : idealFrames[min(i, idealFrames.count - 1)].size
                appliedIdealSizes.append((id: window.id, size: idealSz))

                if i == 0 {
                    // MAIN の実際の配置結果から、左右サイドバーの X 座標と幅を決定
                    // 左サイドバー
                    let leftX = screenAXFrame.minX + gap.outer
                    let leftMaxX = actualFrame.minX - gap.inner
                    actualLeftX = leftX
                    actualLeftW = max(100, leftMaxX - leftX)

                    // 右サイドバー
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
        }

        // ManagedWindow.frame を配置後の値で更新（次回 screenIndex が stale フレームを使わないように）
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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
