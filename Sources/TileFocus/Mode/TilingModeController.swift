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

    /// スクリーンごとにウィンドウをグループ化してタイリングを適用
    private func applyTiling() {
        guard let windowManager else { return }
        let tiledWindows = windowManager.managedWindows.filter { $0.state != .staged }
        guard !tiledWindows.isEmpty else { return }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        // 各スクリーンにウィンドウをグループ化
        // ウィンドウの現在位置から所属スクリーンを判定する
        var windowGroups: [[ManagedWindow]] = Array(repeating: [], count: screens.count)
        for window in tiledWindows {
            let idx = screenIndex(for: window.frame, in: screens)
            windowGroups[idx].append(window)
        }

        // タイリング適用中フラグ（AXWindowMovedNotification ループ防止）
        windowManager.setTilingInProgress(true)
        defer { windowManager.setTilingInProgress(false) }

        // 各スクリーンで独立してレイアウトを適用
        for (idx, windows) in windowGroups.enumerated() {
            guard !windows.isEmpty else { continue }
            let screen = screens[idx]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)

            let layout = resolveLayout(for: windows.count)
            let frames = layout.calculateFrames(
                windowCount: windows.count,
                screenFrame: screenAXFrame
            )

            print("[TilingModeController] スクリーン[\(idx)] \(windows.count)ウィンドウ → \(layout.name)")
            print("  screenAXFrame: \(screenAXFrame)")

            for (i, window) in windows.enumerated() {
                guard i < frames.count else { break }
                let targetFrame = frames[i]

                print("  [\(i)] \(window.appName) → \(targetFrame)")

                guard let axWindow = findAXWindow(for: window) else {
                    print("  [\(i)] ⚠️ AXウィンドウが見つかりません")
                    continue
                }
                AccessibilityHelper.moveAndResize(
                    window: axWindow,
                    to: targetFrame.origin,
                    size: targetFrame.size
                )
            }
        }

        // レイアウト名を表示用に設定（スクリーン0の状態を代表値として使用）
        if let primaryWindows = windowGroups.first(where: { !$0.isEmpty }) {
            let layout = resolveLayout(for: primaryWindows.count)
            windowManager.setCurrentLayout(layout)
        }
    }

    /// 指定した AX フレームが最もよく含まれるスクリーンのインデックスを返す
    private func screenIndex(for axFrame: CGRect, in screens: [NSScreen]) -> Int {
        let appKitFrame = screenManager.axToAppKit(axFrame)
        var bestIndex = 0
        var bestArea: CGFloat = -1
        for (i, screen) in screens.enumerated() {
            let intersection = screen.frame.intersection(appKitFrame)
            let area = intersection.width > 0 && intersection.height > 0
                ? intersection.width * intersection.height
                : 0
            if area > bestArea {
                bestArea = area
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// ウィンドウ数に応じたレイアウトを解決する
    private func resolveLayout(for count: Int) -> any Layout {
        if isAutoLayout {
            return LayoutRegistry.recommendedLayout(for: count)
        }
        return layouts[currentLayoutIndex]
    }

    /// ManagedWindow に対応する AXUIElement を見つける（タイトルマッチ優先）
    private func findAXWindow(for managed: ManagedWindow) -> AXUIElement? {
        AccessibilityHelper.findWindow(for: managed.pid, title: managed.title)
    }
}
