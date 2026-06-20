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

    /// フォーカス中のウィンドウ ID（メインウィンドウ）
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

        // フォーカス適用中フラグを立てて移動通知ループを防ぐ
        windowManager.setTilingInProgress(true)
        defer { windowManager.setTilingInProgress(false) }

        for (index, window) in ordered.enumerated() {
            guard index < frames.count else { break }
            let targetFrame = frames[index]

            // タイトルベースでウィンドウを特定
            guard let axWindow = AccessibilityHelper.findWindow(for: window.pid, title: window.title) else {
                continue
            }

            // 即時移動（asyncAfter は使わない）
            AccessibilityHelper.moveAndResize(
                window: axWindow,
                to: targetFrame.origin,
                size: targetFrame.size
            )

            // メインウィンドウ（index == 0）にフォーカス
            if index == 0 {
                AccessibilityHelper.focus(window: axWindow)
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
