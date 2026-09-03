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
/// - ⌥Tab / ⌥⇧Tab : 王冠（マスターウィンドウ）を次/前のウィンドウへ移動
/// - ⌃⌘+クリック : クリックしたウィンドウを Float Mode の中央に表示
final class HotKeyManager {

    // MARK: - Dependencies

    private weak var windowManager: WindowManager?

    // MARK: - HotKey References（強参照を保持）

    private var hotKeys: [HotKey] = []
    private var eventMonitors: [Any] = []

    // MARK: - Init

    init(windowManager: WindowManager) {
        self.windowManager = windowManager
    }

    // MARK: - Registration

    func registerHotKeys() {
        // Tiling Mode は無効化

        // Focus Mode ON/OFF: Cmd+Ctrl+F
        let focusHK = HotKey(key: Key.f, modifiers: NSEvent.ModifierFlags([.command, .control]))
        focusHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.switchMode(to: .focus) }
        }

        // Float Mode ON/OFF: Cmd+Ctrl+L
        let floatHK = HotKey(key: Key.l, modifiers: NSEvent.ModifierFlags([.command, .control]))
        floatHK.keyDownHandler = { [weak self] in
            Task { @MainActor in self?.windowManager?.switchMode(to: .float) }
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

        // 王冠を次のウィンドウへ移動: Option+Tab
        let nextCrownHK = HotKey(key: Key.tab, modifiers: NSEvent.ModifierFlags([.option]))
        nextCrownHK.keyDownHandler = { [weak self] in
            Task { @MainActor in
                guard AppSettings.shared.isAltTabCrownSelectionEnabled else { return }
                self?.windowManager?.cyclePendingMasterWindow(forward: true)
            }
        }

        // 王冠を前のウィンドウへ移動: Option+Shift+Tab
        let previousCrownHK = HotKey(key: Key.tab, modifiers: NSEvent.ModifierFlags([.option, .shift]))
        previousCrownHK.keyDownHandler = { [weak self] in
            Task { @MainActor in
                guard AppSettings.shared.isAltTabCrownSelectionEnabled else { return }
                self?.windowManager?.cyclePendingMasterWindow(forward: false)
            }
        }

        let globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        let localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        let globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            self?.handleMouseClick(event: event, at: mouseLocation)
        }
        let localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            let mouseLocation = NSEvent.mouseLocation
            self?.handleMouseClick(event: event, at: mouseLocation)
            return event
        }

        hotKeys = [
            focusHK,
            floatHK,
            stageHK,
            restoreHK,
            nextLayoutHK,
            prevLayoutHK,
            masterHK,
            nextCrownHK,
            previousCrownHK
        ]
        eventMonitors = [
            globalFlagsMonitor,
            localFlagsMonitor,
            globalClickMonitor,
            localClickMonitor
        ].compactMap { $0 }
        print("[HotKeyManager] \(hotKeys.count) 個のホットキーを登録")
    }

    func unregisterAll() {
        hotKeys.removeAll()
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
    }

    /// Control+Command 単独のクリックだけを Float Mode の対象選択へ渡す。
    /// Control+Shift など既存のクリック操作は別の監視経路に委ねる。
    func handleMouseClick(event: NSEvent, at mouseLocation: NSPoint) {
        let flags = event.modifierFlags
        guard event.type == .leftMouseDown,
              flags.contains(.command),
              flags.contains(.control),
              !flags.contains(.option),
              !flags.contains(.shift) else {
            return
        }

        Task { @MainActor [weak self] in
            self?.windowManager?.focusWindowAtMetaClick(at: mouseLocation)
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard !event.modifierFlags.contains(.option) else { return }
        Task { @MainActor in
            guard AppSettings.shared.isAltTabCrownSelectionEnabled else {
                self.windowManager?.cancelPendingMasterWindow()
                return
            }
            self.windowManager?.commitPendingMasterWindow()
        }
    }

}
