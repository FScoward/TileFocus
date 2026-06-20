import Foundation
import AppKit

/// Focus Mode のロジックを担当するコントローラー
@MainActor
final class FocusModeController {

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?
    private let screenManager = ScreenManager()
    private let layout = FocusLayout()

    // MARK: - State

    /// フォーカス中のウィンドウ（メインウィンドウ）
    private var focusedWindowID: String?

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Lifecycle

    func activate() {
        guard let windowManager else { return }
        // 現在フォーカスされているアプリのウィンドウをメインに設定
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let pid = frontApp.processIdentifier
            focusedWindowID = windowManager.managedWindows.first { $0.pid == pid }?.id
        } else {
            focusedWindowID = windowManager.managedWindows.first?.id
        }
        applyLayout()
    }

    func deactivate() {
        focusedWindowID = nil
        print("[FocusModeController] 非アクティブ化")
    }

    // MARK: - Layout Application

    /// フォーカスレイアウトを適用
    func applyLayout() {
        guard let windowManager else { return }
        let windows = windowManager.managedWindows.filter { $0.state != .staged }
        guard !windows.isEmpty else { return }

        let screenFrame = screenManager.primaryVisibleFrameForAX
        // フォーカスウィンドウを先頭にして並び替え
        var ordered = windows
        if let focusedID = focusedWindowID,
           let idx = ordered.firstIndex(where: { $0.id == focusedID }) {
            let focused = ordered.remove(at: idx)
            ordered.insert(focused, at: 0)
        }

        let frames = layout.calculateFrames(
            windowCount: ordered.count,
            screenFrame: screenFrame
        )

        for (index, window) in ordered.enumerated() {
            guard index < frames.count else { break }
            let targetFrame = frames[index]
            let axWindows = AccessibilityHelper.getWindows(for: window.pid)
            if let axWindow = axWindows.first {
                AccessibilityHelper.animateMoveAndResize(window: axWindow, to: targetFrame)
                if index == 0 {
                    AccessibilityHelper.focus(window: axWindow)
                }
            }
        }

        print("[FocusModeController] フォーカスレイアウト適用: \(ordered.count) ウィンドウ")
    }

    /// メインウィンドウを切り替える
    func switchMainWindow(to windowID: String) {
        focusedWindowID = windowID
        applyLayout()
    }
}
