import Foundation
import AppKit

/// Tiling Mode のロジックを担当するコントローラー
@MainActor
final class TilingModeController {

    private static let tag = "TilingModeController"

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager: ScreenManager

    // MARK: - State

    private var currentLayoutIndex: Int = 0
    private var isAutoLayout: Bool = true
    private let layouts: [any Layout] = LayoutRegistry.allLayouts
    private var retileWorkItem: DispatchWorkItem?

    // MARK: - Init

    init(windowManager: WindowManager, screenManager: ScreenManager) {
        self.windowManager = windowManager
        self.screenManager = screenManager
    }

    // MARK: - Lifecycle

    func activate() {
        Log.info(Self.tag, "activate()")
        retile()
    }

    func deactivate() {
        retileWorkItem?.cancel()
        retileWorkItem = nil
        Log.info(Self.tag, "deactivate()")
    }

    // MARK: - Layout Control

    func nextLayout() {
        isAutoLayout = false
        currentLayoutIndex = (currentLayoutIndex + 1) % layouts.count
        let layout = layouts[currentLayoutIndex]
        Log.info(Self.tag, "nextLayout → \(layout.name)")
        windowManager?.setCurrentLayout(layout)
        retile()
    }

    func previousLayout() {
        isAutoLayout = false
        currentLayoutIndex = (currentLayoutIndex - 1 + layouts.count) % layouts.count
        let layout = layouts[currentLayoutIndex]
        Log.info(Self.tag, "previousLayout → \(layout.name)")
        windowManager?.setCurrentLayout(layout)
        retile()
    }

    // MARK: - Tiling

    func retile(debounce: TimeInterval = 0.05) {
        retileWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.applyTiling()
        }
        retileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    // MARK: - Private

    private func applyTiling() {
        guard let windowManager else { return }
        let tiledWindows = windowManager.managedWindows.filter { $0.state != .staged }

        Log.info(Self.tag, "applyTiling() 開始 対象=\(tiledWindows.count)枚")
        for (i, w) in tiledWindows.enumerated() {
            Log.debug(Self.tag, "  [\(i)] \"\(w.appName) - \(w.title)\" frame=\(w.frame)")
        }

        guard !tiledWindows.isEmpty else {
            Log.warn(Self.tag, "applyTiling: 対象なし")
            return
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            Log.error(Self.tag, "applyTiling: NSScreen.screens が空")
            return
        }

        // スクリーンごとにグループ化
        var windowGroups: [[ManagedWindow]] = Array(repeating: [], count: screens.count)
        for window in tiledWindows {
            let idx = screenIndex(for: window.frame, in: screens)
            Log.debug(Self.tag, "  \"\(window.appName)\" → Screen[\(idx)]")
            windowGroups[idx].append(window)
        }

        windowManager.setTilingInProgress(true)
        defer { windowManager.setTilingInProgress(false) }

        for (idx, windows) in windowGroups.enumerated() {
            guard !windows.isEmpty else { continue }
            let screen = screens[idx]
            let screenAXFrame = screenManager.visibleFrameInAX(for: screen)
            let layout = resolveLayout(for: windows.count)

            Log.info(Self.tag, "Screen[\(idx)] \(windows.count)枚 layout=\(layout.name) AXFrame=\(screenAXFrame)")

            let frames = layout.calculateFrames(windowCount: windows.count, screenFrame: screenAXFrame)

            for (i, window) in windows.enumerated() {
                guard i < frames.count else { break }
                let targetFrame = frames[i]
                Log.info(Self.tag, "  [\(i)] \"\(window.appName) - \(window.title)\" → \(targetFrame)")

                guard let axWindow = findAXWindow(for: window) else {
                    Log.error(Self.tag, "  ⚠️ AXウィンドウが見つかりません pid=\(window.pid) title=\"\(window.title)\"")
                    continue
                }
                AccessibilityHelper.moveAndResize(window: axWindow, to: targetFrame.origin, size: targetFrame.size)
            }
        }

        Log.info(Self.tag, "applyTiling() 完了")

        // レイアウト名をUIに反映
        if let primaryWindows = windowGroups.first(where: { !$0.isEmpty }) {
            windowManager.setCurrentLayout(resolveLayout(for: primaryWindows.count))
        }
    }

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

    private func resolveLayout(for count: Int) -> any Layout {
        if isAutoLayout {
            return LayoutRegistry.recommendedLayout(for: count)
        }
        return layouts[currentLayoutIndex]
    }

    private func findAXWindow(for managed: ManagedWindow) -> AXUIElement? {
        AccessibilityHelper.findWindow(for: managed.pid, title: managed.title)
    }
}
