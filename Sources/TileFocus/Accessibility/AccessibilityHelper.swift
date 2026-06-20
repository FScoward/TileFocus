import Foundation
import AppKit

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

/// AXUIElement API のラッパーユーティリティ
/// ウィンドウの位置・サイズ取得/設定、タイトル取得、ウィンドウ列挙などを提供
enum AccessibilityHelper {

    private static let tag = "AccessibilityHelper"

    // MARK: - Window Enumeration

    /// 指定 PID のアプリが持つ全 AXUIElement（ウィンドウ）を返す
    static func getWindows(for pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &value
        )
        guard result == .success,
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows
    }

    /// タイリング可能なウィンドウのみを返す（シート・パネル・最小化を除外）
    static func getTileableWindows(for pid: pid_t) -> [AXUIElement] {
        getWindows(for: pid).filter { isTileable($0) }
    }

    /// ウィンドウがタイリング対象かどうか判定
    ///
    /// 条件:
    /// - role が AXWindow
    /// - subrole が AXStandardWindow もしくは空（シート・フローティング等を除外）
    /// - サイズ変更可能
    /// - 最小化されていない
    /// - サイズが 100x100 以上
    static func isTileable(_ window: AXUIElement) -> Bool {
        // role チェック
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard role == kAXWindowRole as String else {
            return false
        }

        // subrole チェック (シート・フローティング等を除外。空は許容)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""
        if !subrole.isEmpty && subrole != kAXStandardWindowSubrole {
            Log.debug(tag, "isTileable=false subrole=\(subrole) title=\(getTitle(of: window) ?? "")")
            return false
        }

        // リサイズ可能かチェック
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable)
        guard settable.boolValue else {
            Log.debug(tag, "isTileable=false not-resizable title=\(getTitle(of: window) ?? "")")
            return false
        }

        // 最小化されていないかチェック
        if isMinimized(window) {
            Log.debug(tag, "isTileable=false minimized title=\(getTitle(of: window) ?? "")")
            return false
        }

        // フルスクリーンでないかチェック
        if isFullScreen(window) {
            Log.debug(tag, "isTileable=false fullscreen title=\(getTitle(of: window) ?? "")")
            return false
        }

        // 最小サイズチェック
        guard let frame = getFrame(of: window),
              frame.width >= 100, frame.height >= 100 else {
            Log.debug(tag, "isTileable=false too-small title=\(getTitle(of: window) ?? "")")
            return false
        }

        return true
    }

    /// ウィンドウがメインウィンドウ（フォーカス中）か判定
    static func isMainWindow(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMainAttribute as CFString, &value)
        return (value as? Bool) ?? false
    }

    /// PID と CGWindowID / タイトルで AXUIElement を検索する（マルチウィンドウアプリ対応）
    static func findWindow(for pid: pid_t, windowID: CGWindowID, title: String) -> AXUIElement? {
        let windows = getWindows(for: pid)
        Log.debug(tag, "findWindow pid=\(pid) windowID=\(windowID) title=\"\(title)\" windowsCount=\(windows.count)")
        if windows.count <= 1 {
            Log.debug(tag, "  → windows.count <= 1, 返却: \(windows.first.flatMap { getTitle(of: $0) } ?? "nil")")
            return windows.first
        }

        // 1. CGWindowID で厳密にマッチング
        for window in windows {
            let wID = getWindowID(of: window) ?? 0
            if wID == windowID {
                Log.debug(tag, "  → CGWindowID 一致で返却: \"\(getTitle(of: window) ?? "")\" (windowID=\(wID))")
                return window
            }
        }

        // 2. タイトルでマッチング（フォールバック）
        if !title.isEmpty, let match = windows.first(where: { getTitle(of: $0) == title }) {
            Log.debug(tag, "  → タイトル一致で返却: \"\(title)\" (windowID=\(getWindowID(of: match) ?? 0))")
            return match
        }

        Log.debug(tag, "  → マッチなし、first返却: \"\(windows.first.flatMap { getTitle(of: $0) } ?? "")\"")
        return windows.first
    }

    // MARK: - Frame (Position + Size)

    /// ウィンドウのフレームを取得（Accessibility 座標系: 左上原点）
    static func getFrame(of window: AXUIElement) -> CGRect? {
        guard let position = getPosition(of: window),
              let size = getSize(of: window) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// ウィンドウの位置を取得
    static func getPosition(of window: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &value
        )
        guard result == .success, let axValue = value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// ウィンドウのサイズを取得
    static func getSize(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXSizeAttribute as CFString, &value
        )
        guard result == .success, let axValue = value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    // MARK: - Move & Resize

    /// ウィンドウを指定位置・サイズに即時移動し、リサイズが成功したかを返す
    @discardableResult
    static func moveAndResize(window: AXUIElement, to position: CGPoint, size: CGSize) -> Bool {
        let title = getTitle(of: window) ?? "?"
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let beforeFrame = getFrame(of: window)
        
        // 1. 先にサイズを設定（スナップやリサイズ制限を確定させる）
        let success = setSize(of: window, to: size)
        
        // 20ミリ秒のスリープを入れてOSのWindowServerに処理の隙間を与える（要求の衝突防止）
        usleep(20000)
        
        // 2. その後に位置を設定（リサイズによる座標の戻りを防ぐ）
        setPosition(of: window, to: position)
        
        Log.debug(tag, "moveAndResize pid=\(pid) \"\(title)\" success=\(success) → pos=\(position) size=\(size) (beforeFrame=\(beforeFrame.map { "\($0)" } ?? "nil"))")
        return success
    }

    /// ウィンドウを指定フレームに即時移動・リサイズ
    @discardableResult
    static func setFrame(_ frame: CGRect, to window: AXUIElement) -> Bool {
        return moveAndResize(window: window, to: frame.origin, size: frame.size)
    }

    // MARK: - Title

    /// ウィンドウのタイトルを取得
    static func getTitle(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &value
        )
        guard result == .success else { return nil }
        return value as? String
    }

    // MARK: - Window ID

    /// AXUIElement から CGWindowID を取得
    static func getWindowID(of window: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(window, &windowID)
        if result != .success {
            Log.warn(tag, "getWindowID: _AXUIElementGetWindow 失敗 error=\(result.rawValue) title=\"\(getTitle(of: window) ?? "")\"")
            return nil
        }
        return windowID
    }

    // MARK: - Minimize / Restore

    static func minimize(window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, true as CFTypeRef)
    }

    static func restore(window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
    }

    // MARK: - Focus

    static func focus(window: AXUIElement) {
        let title = getTitle(of: window) ?? "?"
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        Log.debug(tag, "focus \"\(title)\" (pid=\(pid))")

        // 1. まずそのプロセス自体をアクティブにする
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        // 2. ウィンドウをメインにして最前面に上げる
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    // MARK: - Minimized Check

    static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXMinimizedAttribute as CFString, &value
        )
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    // MARK: - Private Helpers

    private static func setPosition(of window: AXUIElement, to position: CGPoint) {
        var point = position
        guard let posValue = AXValueCreate(.cgPoint, &point) else { return }
        let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        if result != .success {
            Log.warn(tag, "setPosition failed result=\(result.rawValue) pos=\(position)")
        }
    }

    private static func setSize(of window: AXUIElement, to size: CGSize) -> Bool {
        var sz = size
        guard let sizeValue = AXValueCreate(.cgSize, &sz) else { return false }
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if result != .success {
            Log.warn(tag, "setSize failed result=\(result.rawValue) size=\(size)")
            return false
        }
        return true
    }

    /// ウィンドウがフルスクリーン状態かどうか判定
    static func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        guard result == .success, let boolValue = value as? Bool else { return false }
        return boolValue
    }

    /// 現在のスペース（画面上）に存在する CGWindowID のセットを取得する
    static func getOnScreenWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.excludeDesktopElements, .optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids = Set<CGWindowID>()
        for info in list {
            if let wID = info[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(wID)
            }
        }
        return ids
    }
}
