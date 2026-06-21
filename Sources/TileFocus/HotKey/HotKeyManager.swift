import AppKit
import Foundation
import HotKey

/// グローバルホットキーの登録・管理
///
/// ショートカット一覧:
/// - ⌃⌘T  : Tiling Mode ON/OFF
/// - ⌃⌘F  : Focus Mode ON/OFF
/// - ⌃⌘M  : フロントウィンドウをマスターに是抜
/// - ⌃⌘S  : フォーカス中のウィンドウを格納
/// - ⌃⌘R  : 格納ウィンドウを全復帰
/// - ⌃⌘→ : 次のレイアウトプリセット
/// - ⌃⌘← : 前のレイアウトプリセット
final class HotKeyManager {

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?

    // MARK: - HotKey References（強参照を保持）

    private var hotKeys: [HotKey] = []

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Registration

    func registerHotKeys() {
        // Tiling Mode ON/OFF: Cmd+Ctrl+T
        let tilingHK = HotKey(key: Key.t, modifiers: NSEvent.ModifierFlags([.command, .control]))
        tilingHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.switchMode(to: .tiling) }
        }

        // Focus Mode ON/OFF: Cmd+Ctrl+F
        let focusHK = HotKey(key: Key.f, modifiers: NSEvent.ModifierFlags([.command, .control]))
        focusHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.switchMode(to: .focus) }
        }

        // フォーカス中のウィンドウを格納: Cmd+Ctrl+S
        let stageHK = HotKey(key: Key.s, modifiers: NSEvent.ModifierFlags([.command, .control]))
        stageHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.stageFocusedWindow() }
        }

        // 全格納ウィンドウを復帰: Cmd+Ctrl+R
        let restoreHK = HotKey(key: Key.r, modifiers: NSEvent.ModifierFlags([.command, .control]))
        restoreHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.unstageAllWindows() }
        }

        // 次のレイアウト: Cmd+Ctrl+→
        let nextLayoutHK = HotKey(key: Key.rightArrow, modifiers: NSEvent.ModifierFlags([.command, .control]))
        nextLayoutHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.nextLayout() }
        }

        // 前のレイアウト: Cmd+Ctrl+←
        let prevLayoutHK = HotKey(key: Key.leftArrow, modifiers: NSEvent.ModifierFlags([.command, .control]))
        prevLayoutHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.previousLayout() }
        }

        // フロントウィンドウをマスターに是抜: Cmd+Ctrl+M
        let masterHK = HotKey(key: Key.m, modifiers: NSEvent.ModifierFlags([.command, .control]))
        masterHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.promoteCurrentWindowToMaster() }
        }

        hotKeys = [tilingHK, focusHK, stageHK, restoreHK, nextLayoutHK, prevLayoutHK, masterHK]
        print("[HotKeyManager] \(hotKeys.count) 個のホットキーを登録")
    }

    func unregisterAll() {
        hotKeys.removeAll()
    }

}

