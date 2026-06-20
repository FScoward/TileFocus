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
        AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
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
        AXValueGetValue(axValue as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - Move & Resize

    /// ウィンドウを指定位置・サイズに移動（即時）
    /// - Parameters:
    ///   - window: 対象の AXUIElement
    ///   - position: 新しい位置（Accessibility 座標系: 左上原点）
    ///   - size: 新しいサイズ
    static func moveAndResize(window: AXUIElement, to position: CGPoint, size: CGSize) {
        setPosition(of: window, to: position)
        setSize(of: window, to: size)
    }

    /// PID からウィンドウを特定して移動・リサイズ
    static func moveAndResizeWindow(pid: pid_t, newPosition: CGPoint, newSize: CGSize) {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)

        guard let windowList = value as? [AXUIElement],
              let window = windowList.first else { return }

        var pos = newPosition
        var sz = newSize

        guard let positionRef = AXValueCreate(.cgPoint, &pos),
              let sizeRef = AXValueCreate(.cgSize, &sz) else { return }

        // 位置を先に設定してからサイズを設定する（順序重要）
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionRef)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeRef)
    }

    /// ウィンドウを指定フレームに移動・リサイズ
    static func setFrame(_ frame: CGRect, to window: AXUIElement) {
        moveAndResize(window: window, to: frame.origin, size: frame.size)
    }

    /// アニメーション付き移動（段階的に位置を変化させる）
    /// - Parameters:
    ///   - window: 対象の AXUIElement
    ///   - targetFrame: 目標フレーム
    ///   - steps: アニメーションステップ数
    ///   - duration: アニメーション時間（秒）
    static func animateMoveAndResize(
        window: AXUIElement,
        to targetFrame: CGRect,
        steps: Int = 8,
        duration: TimeInterval = 0.2
    ) {
        guard let currentFrame = getFrame(of: window) else {
            setFrame(targetFrame, to: window)
            return
        }

        let interval = duration / Double(steps)

        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let interpolatedOrigin = CGPoint(
                x: currentFrame.origin.x + (targetFrame.origin.x - currentFrame.origin.x) * progress,
                y: currentFrame.origin.y + (targetFrame.origin.y - currentFrame.origin.y) * progress
            )
            let interpolatedSize = CGSize(
                width: currentFrame.width + (targetFrame.width - currentFrame.width) * progress,
                height: currentFrame.height + (targetFrame.height - currentFrame.height) * progress
            )
            let delay = interval * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                moveAndResize(window: window, to: interpolatedOrigin, size: interpolatedSize)
            }
        }
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
    /// CGWindowListCopyWindowInfo を利用して PID とタイトルからマッチングする
    static func getWindowID(of window: AXUIElement) -> CGWindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let title = getTitle(of: window) ?? ""

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  wPid == pid else { continue }
            // タイトルが一致するウィンドウを探す（空タイトルは最初にマッチ）
            let wName = info[kCGWindowName as String] as? String ?? ""
            if title.isEmpty || wName == title {
                if let wID = info[kCGWindowNumber as String] as? CGWindowID {
                    return wID
                }
            }
        }
        // フォールバック: 同じ PID の最初のウィンドウ
        for info in list {
            guard let wPid = info[kCGWindowOwnerPID as String] as? pid_t,
                  wPid == pid else { continue }
            if let wID = info[kCGWindowNumber as String] as? CGWindowID {
                return wID
            }
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
