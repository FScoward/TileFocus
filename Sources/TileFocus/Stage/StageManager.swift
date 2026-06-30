import Foundation
import AppKit

/// 格納ウィンドウの管理クラス
/// ウィンドウを Dock にしまって「格納」し、リストで管理する
final class StageManager {

    // MARK: - State

    /// 格納中のウィンドウリスト
    private var staged: [ManagedWindow] = []

    // MARK: - Stage / Unstage

    /// ウィンドウを格納する
    @MainActor
    func stage(window: ManagedWindow, windowManager: WindowManager, forceDock: Bool = false) {
        guard window.state != .staged else { return }

        var mutableWindow = window
        // 格納前のフレームを記憶
        mutableWindow.frameBeforeStaging = window.frame
        mutableWindow.state = .staged

        // 格納方法に基づいて処理
        let method = forceDock ? StageMethod.dock : AppSettings.shared.stageMethod
        if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
            windowManager.setTilingInProgress(true)
            switch method {
            case .offscreen:
                Log.warn("StageManager", "stageMethod=offscreen は非推奨のため Dock 格納にフォールバックします")
                AccessibilityHelper.minimize(window: axWindow)
            case .dock:
                AccessibilityHelper.minimize(window: axWindow)
            }
            windowManager.finishTilingInProgressAfterWindowSettles()
        }

        // 管理リストから除去、格納リストへ追加
        var managedWindows = windowManager.managedWindows
        managedWindows.removeAll { $0.id == window.id }
        windowManager.updateManagedWindows(managedWindows)

        staged.append(mutableWindow)
        windowManager.updateStagedWindows(staged)

        print("[StageManager] 格納: \(window.appName) - \(window.title) (method=\(method))")

        // タイリング中なら残りのウィンドウを再タイリング
        if windowManager.currentMode == .tiling {
            windowManager.requestRetile()
        } else if windowManager.currentMode == .focus || windowManager.currentMode == .float {
            windowManager.requestFocusLayoutUpdate()
        }
    }

    /// 格納ウィンドウを復帰させる
    @MainActor
    func unstage(window: ManagedWindow, windowManager: WindowManager) {
        guard let idx = staged.firstIndex(where: { $0.id == window.id }) else { return }

        var restoredWindow = staged[idx]
        restoredWindow.state = .tiled

        // 格納前のフレームに戻す（なければ画面中央に適当なサイズで）
        let targetFrame = restoredWindow.frameBeforeStaging ?? defaultFrame()
        restoredWindow.frame = targetFrame
        restoredWindow.frameBeforeStaging = nil

        // 格納方法に基づいて復帰処理
        let method = AppSettings.shared.stageMethod
        if let axWindow = AccessibilityHelper.findWindow(for: window.pid, windowID: window.windowID, title: window.title) {
            windowManager.setTilingInProgress(true)
            switch method {
            case .offscreen:
                if AccessibilityHelper.isMinimized(axWindow) {
                    AccessibilityHelper.restore(window: axWindow)
                }
                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
            case .dock:
                AccessibilityHelper.restore(window: axWindow)
                // 復帰直後はサイズ変更が拒否される場合があるため、一旦少し待たずに即時移動を試み、
                // OS側で復帰した後に確実にサイズと位置を合わせる
                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
            }
            windowManager.finishTilingInProgressAfterWindowSettles()
            AccessibilityHelper.focus(window: axWindow)
        }

        // リスト更新
        staged.remove(at: idx)
        windowManager.updateStagedWindows(staged)

        var managedWindows = windowManager.managedWindows
        managedWindows.append(restoredWindow)
        windowManager.updateManagedWindows(managedWindows)

        // タイリング中なら全体を再タイリング
        if windowManager.currentMode == .tiling {
            windowManager.requestRetile()
        } else if windowManager.currentMode == .focus || windowManager.currentMode == .float {
            windowManager.requestFocusLayoutUpdate()
        }

        print("[StageManager] 復帰: \(window.appName) - \(window.title)")
    }

    /// 全格納ウィンドウを復帰させる
    @MainActor
    func unstageAll(windowManager: WindowManager) {
        let toRestore = staged
        for window in toRestore {
            unstage(window: window, windowManager: windowManager)
        }
    }

    /// 格納中のウィンドウリストを外部の最新状態と同期する
    @MainActor
    func syncStagedWindows(_ windows: [ManagedWindow]) {
        self.staged = windows
    }

    // MARK: - Private

    private func defaultFrame() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 100, y: 100, width: 800, height: 600)
        }
        // 画面中央に 70% サイズで配置（AppKit 座標）
        let w = screen.visibleFrame.width * 0.7
        let h = screen.visibleFrame.height * 0.7
        let x = screen.visibleFrame.midX - w / 2
        let y = screen.visibleFrame.midY - h / 2
        // Accessibility 座標に変換
        let screenManager = ScreenManager()
        let nsRect = CGRect(x: x, y: y, width: w, height: h)
        return screenManager.convertToAXCoordinates(nsRect, in: screen)
    }
}
