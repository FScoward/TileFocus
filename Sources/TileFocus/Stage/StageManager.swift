import Foundation
import AppKit

/// 格納ウィンドウの管理クラス
/// ウィンドウを画面外に移動して「格納」し、リストで管理する
final class StageManager {

    // MARK: - State

    /// 格納中のウィンドウリスト
    private var staged: [ManagedWindow] = []

    /// 格納位置: 画面左端外側
    private let stagingOffset: CGFloat = -2000

    // MARK: - Stage / Unstage

    /// ウィンドウを格納する
    @MainActor
    func stage(window: ManagedWindow, windowManager: WindowManager) {
        guard window.state != .staged else { return }

        var mutableWindow = window
        // 格納前のフレームを記憶
        mutableWindow.frameBeforeStaging = window.frame
        mutableWindow.state = .staged

        // ウィンドウを画面外に移動
        let hiddenPosition = CGPoint(x: stagingOffset, y: window.frame.origin.y)
        let axWindows = AccessibilityHelper.getWindows(for: window.pid)
        if let axWindow = axWindows.first {
            AccessibilityHelper.moveAndResize(
                window: axWindow,
                to: hiddenPosition,
                size: window.frame.size
            )
        }

        // 管理リストを更新
        var managedWindows = windowManager.managedWindows
        if let idx = managedWindows.firstIndex(where: { $0.id == window.id }) {
            managedWindows.remove(at: idx)
            windowManager.updateManagedWindows(managedWindows)
        }

        staged.append(mutableWindow)
        windowManager.updateStagedWindows(staged)

        print("[StageManager] 格納: \(window.appName) - \(window.title)")
    }

    /// 格納ウィンドウを復帰させる
    @MainActor
    func unstage(window: ManagedWindow, windowManager: WindowManager) {
        guard let idx = staged.firstIndex(where: { $0.id == window.id }) else { return }

        var restoredWindow = staged[idx]
        restoredWindow.state = .tiled

        // 格納前のフレームに戻す
        let targetFrame = restoredWindow.frameBeforeStaging ?? CGRect(
            x: 100, y: 100, width: 800, height: 600
        )
        restoredWindow.frame = targetFrame
        restoredWindow.frameBeforeStaging = nil

        // ウィンドウを元の位置に戻す
        let axWindows = AccessibilityHelper.getWindows(for: window.pid)
        if let axWindow = axWindows.first {
            AccessibilityHelper.animateMoveAndResize(window: axWindow, to: targetFrame)
            AccessibilityHelper.focus(window: axWindow)
        }

        // リスト更新
        staged.remove(at: idx)
        windowManager.updateStagedWindows(staged)

        var managedWindows = windowManager.managedWindows
        managedWindows.append(restoredWindow)
        windowManager.updateManagedWindows(managedWindows)

        // タイリング再適用
        if windowManager.currentMode == .tiling {
            // TilingModeController は WindowManager 経由で retile を呼ぶ（Phase 3 で連携強化）
            print("[StageManager] タイリング再適用をリクエスト")
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
}
