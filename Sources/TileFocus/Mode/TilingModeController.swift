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

    /// 自動選択モードか否か
    private var isAutoLayout: Bool = true

    /// レイアウト一覧
    private let layouts: [any Layout] = LayoutRegistry.allLayouts

    /// デバウンス用 WorkItem（連続した retile 呼び出しをまとめる）
    private var retileWorkItem: DispatchWorkItem?

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
        retileWorkItem?.cancel()
        retileWorkItem = nil
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

    // MARK: - Tiling（デバウンス付き）

    /// タイリングをデバウンスして適用（連続呼び出しをまとめる）
    func retile(debounce: TimeInterval = 0.05) {
        retileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyTiling()
        }
        retileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    // MARK: - Private

    /// 実際にタイリングを適用する（内部メソッド）
    private func applyTiling() {
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

        // タイリング中フラグを立てて移動通知の無限ループを防ぐ
        windowManager.setTilingInProgress(true)
        defer { windowManager.setTilingInProgress(false) }

        for (index, window) in tiledWindows.enumerated() {
            guard index < frames.count else { break }
            let targetFrame = frames[index]

            // WindowID でマッチングして正しいウィンドウを特定
            let axWindow = findAXWindow(for: window)
            guard let axWindow else {
                print("[TilingModeController] ウィンドウが見つかりません: \(window.appName) - \(window.title)")
                continue
            }

            // アニメーションなしで直接移動（asyncAfter による連鎖を防ぐ）
            AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
        }

        print("[TilingModeController] タイリング適用: \(tiledWindows.count) ウィンドウ, レイアウト: \(layout.name)")
    }

    /// ManagedWindow に対応する AXUIElement を探す
    private func findAXWindow(for managed: ManagedWindow) -> AXUIElement? {
        let axWindows = AccessibilityHelper.getWindows(for: managed.pid)
        guard !axWindows.isEmpty else { return nil }

        // WindowID が 0（不明）の場合は最初のウィンドウを返す
        if managed.windowID == 0 {
            return axWindows.first
        }

        // タイトルで一致するウィンドウを探す
        for axWindow in axWindows {
            let title = AccessibilityHelper.getTitle(of: axWindow) ?? ""
            if title == managed.title {
                return axWindow
            }
        }

        // フォールバック: 最初のウィンドウ
        return axWindows.first
    }
}
