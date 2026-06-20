import Foundation
import AppKit

/// Tiling Mode のロジックを担当するコントローラー
@MainActor
final class TilingModeController {

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager: ScreenManager

    // MARK: - State

    /// 現在選択されているレイアウトのインデックス
    private var currentLayoutIndex: Int = 0

    /// 自動選択モードか否か（nil = 自動）
    private var isAutoLayout: Bool = true

    /// レイアウト一覧
    private let layouts: [any Layout] = LayoutRegistry.allLayouts

    // MARK: - Init

    init(windowManager: WindowManager, screenManager: ScreenManager) {
        self.windowManager = windowManager
        self.screenManager = screenManager
    }

    // MARK: - Lifecycle

    func activate() {
        retile()
    }

    func deactivate() {
        // ウィンドウを元の位置に戻す（Phase 5 で強化予定）
        print("[TilingModeController] 非アクティブ化")
    }

    // MARK: - Layout Control

    /// 次のレイアウトに切り替え
    func nextLayout() {
        isAutoLayout = false
        currentLayoutIndex = (currentLayoutIndex + 1) % layouts.count
        windowManager?.setCurrentLayout(layouts[currentLayoutIndex])
        retile()
    }

    /// 前のレイアウトに切り替え
    func previousLayout() {
        isAutoLayout = false
        currentLayoutIndex = (currentLayoutIndex - 1 + layouts.count) % layouts.count
        windowManager?.setCurrentLayout(layouts[currentLayoutIndex])
        retile()
    }

    // MARK: - Tiling

    /// 現在のウィンドウリストに対してタイリングを適用
    func retile() {
        guard let windowManager else { return }
        let tiledWindows = windowManager.managedWindows.filter { $0.state != .staged }
        guard !tiledWindows.isEmpty else { return }

        let screenFrame = screenManager.primaryVisibleFrameForAX
        let layout: any Layout

        if isAutoLayout {
            layout = LayoutRegistry.recommendedLayout(for: tiledWindows.count)
            windowManager.setCurrentLayout(layout)
        } else {
            layout = layouts[currentLayoutIndex]
        }

        let frames = layout.calculateFrames(
            windowCount: tiledWindows.count,
            screenFrame: screenFrame
        )

        for (index, window) in tiledWindows.enumerated() {
            guard index < frames.count else { break }
            let targetFrame = frames[index]
            let axWindows = AccessibilityHelper.getWindows(for: window.pid)
            // pid の最初のウィンドウを対象にする（Phase 3 で WindowID マッチングに強化予定）
            if let axWindow = axWindows.first {
                AccessibilityHelper.animateMoveAndResize(
                    window: axWindow,
                    to: targetFrame
                )
            }
        }

        print("[TilingModeController] タイリング適用: \(tiledWindows.count) ウィンドウ, レイアウト: \(layout.name)")
    }
}
