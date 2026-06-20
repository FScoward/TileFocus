import Foundation
import AppKit

/// AXUIElement API のラッパーユーティリティ
/// ウィンドウの位置・サイズ取得/設定、タイトル取得、ウィンドウ列挙などを提供
enum AccessibilityHelper {

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

    /// タイトルで AXUIElement を検索する（マルチウィンドウアプリ対応）
    static func findWindow(for pid: pid_t, title: String) -> AXUIElement? {
        let windows = getWindows(for: pid)
        if title.isEmpty { return windows.first }
        // タイトル完全一致
        if let match = windows.first(where: { getTitle(of: $0) == title }) {
            return match
        }
        // フォールバック: 最初のウィンドウ
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

    /// ウィンドウを指定位置・サイズに即時移動（同期・安全）
    ///
    /// - Note: 位置を先に設定してからサイズを設定する（順序重要）
    /// - Note: asyncAfter は使わない → AXWindowMovedNotification の連鎖を防ぐ
    static func moveAndResize(window: AXUIElement, to position: CGPoint, size: CGSize) {
        setPosition(of: window, to: position)
        setSize(of: window, to: size)
    }

    /// ウィンドウを指定フレームに即時移動・リサイズ
    static func setFrame(_ frame: CGRect, to window: AXUIElement) {
        moveAndResize(window: window, to: frame.origin, size: frame.size)
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
    /// CGWindowListCopyWindowInfo を PID フィルタで効率的に検索
    static func getWindowID(of window: AXUIElement) -> CGWindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let title = getTitle(of: window) ?? ""

        // スクリーン上のウィンドウ情報を取得（軽量オプション）
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // 同じ PID のウィンドウに絞ってタイトルマッチ
        let pidWindows = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid }

        // タイトル完全一致
        if !title.isEmpty {
            for info in pidWindows {
                let wName = info[kCGWindowName as String] as? String ?? ""
                if wName == title, let wID = info[kCGWindowNumber as String] as? CGWindowID {
                    return wID
                }
            }
        }

        // フォールバック: 同 PID の最初のウィンドウ
        if let first = pidWindows.first, let wID = first[kCGWindowNumber as String] as? CGWindowID {
            return wID
        }

        return nil
    }

    // MARK: - Minimize / Restore

    /// ウィンドウを最小化
    static func minimize(window: AXUIElement) {
        AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, true as CFTypeRef
        )
    }

    /// ウィンドウを最小化から復元
    static func restore(window: AXUIElement) {
        AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, false as CFTypeRef
        )
    }

    // MARK: - Focus

    /// ウィンドウにフォーカスを当てる
    static func focus(window: AXUIElement) {
        AXUIElementSetAttributeValue(
            window, kAXMainAttribute as CFString, true as CFTypeRef
        )
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    // MARK: - Minimized Check

    /// ウィンドウが最小化されているかチェック
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
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
    }

    private static func setSize(of window: AXUIElement, to size: CGSize) {
        var sz = size
        guard let sizeValue = AXValueCreate(.cgSize, &sz) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}
