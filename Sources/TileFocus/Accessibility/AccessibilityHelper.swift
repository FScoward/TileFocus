import Foundation
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: inout CGWindowID) -> AXError

// SkyLight.framework 内のプライベートAPI
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?

/// AXUIElement API のラッパーユーティリティ
/// ウィンドウの位置・サイズ取得/設定、タイトル取得、ウィンドウ列挙などを提供
enum AccessibilityHelper {

    #if DEBUG
    static var mockWindowAtPoint: AXUIElement? = nil
    static var mockWindowID: CGWindowID? = nil
    static var mockWindowTitle: String? = nil
    static var mockWindowPid: pid_t? = nil
    #endif

    private static let tag = "AccessibilityHelper"
    private static var moveAndResizeLogID: UInt64 = 0

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

    private struct FrameCheck {
        let frame: CGRect
        let xDiff: CGFloat
        let yDiff: CGFloat
        let widthDiff: CGFloat
        let heightDiff: CGFloat

        var maxDiff: CGFloat {
            max(xDiff, yDiff, widthDiff, heightDiff)
        }

        var isAcceptable: Bool {
            xDiff <= 10 && yDiff <= 10 && widthDiff <= 10 && heightDiff <= 10
        }
    }

    private static func checkFrame(_ frame: CGRect, against position: CGPoint, size: CGSize) -> FrameCheck {
        FrameCheck(
            frame: frame,
            xDiff: abs(frame.minX - position.x),
            yDiff: abs(frame.minY - position.y),
            widthDiff: abs(frame.width - size.width),
            heightDiff: abs(frame.height - size.height)
        )
    }

    private static func applyMoveAndResizePass(window: AXUIElement, to position: CGPoint, size: CGSize, waitTime: useconds_t) -> Bool {
        let before = getFrame(of: window) ?? .zero
        let isExpanding = size.width > before.width || size.height > before.height
        if isExpanding {
            setPosition(of: window, to: position)
            usleep(waitTime)
            return setSize(of: window, to: size)
        } else {
            let success = setSize(of: window, to: size)
            usleep(waitTime)
            setPosition(of: window, to: position)
            return success
        }
    }

    /// ウィンドウを指定位置・サイズに即時移動し、リサイズが成功したかを返す
    @discardableResult
    static func moveAndResize(window: AXUIElement, to position: CGPoint, size: CGSize) -> Bool {
        let title = getTitle(of: window) ?? "?"
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let beforeFrameForLog = getFrame(of: window) ?? .zero
        moveAndResizeLogID &+= 1
        let logID = moveAndResizeLogID
        
        let isExpanding = size.width > beforeFrameForLog.width || size.height > beforeFrameForLog.height
        let waitTime: useconds_t = 20000 // 20ms
        let retrySettleTime: useconds_t = 70000 // 70ms
        let minimumRetryCount = 8
        let maxRetryCount = 24
        let progressTolerance: CGFloat = 2
        let maxNoProgressCount = 5
        Log.debug(tag, "[move#\(logID)] start pid=\(pid) \"\(title)\" before=\(beforeFrameForLog) requestPos=\(position) requestSize=\(size) isExpanding=\(isExpanding)")
        
        if isExpanding {
            setPosition(of: window, to: position)
            usleep(waitTime)
            _ = setSize(of: window, to: size)
        } else {
            _ = setSize(of: window, to: size)
            usleep(waitTime)
            setPosition(of: window, to: position)
        }
        Log.debug(tag, "[move#\(logID)] after pass1 frame=\(getFrame(of: window).map { "\($0)" } ?? "nil")")

        // OSがウィンドウのフレーム補正やアニメーションをある程度進めるのを待つ
        usleep(40000) // 40ms
        Log.debug(tag, "[move#\(logID)] after settle frame=\(getFrame(of: window).map { "\($0)" } ?? "nil")")

        // パス2：1回目の競合で未適用になった部分や、OSによる微小なズレをダメ押しで矯正
        setPosition(of: window, to: position)
        let success = setSize(of: window, to: size)
        usleep(waitTime)
        setPosition(of: window, to: position)
        Log.debug(tag, "[move#\(logID)] after pass2 frame=\(getFrame(of: window).map { "\($0)" } ?? "nil") setSizeSuccess=\(success)")
        
        var rawSetSizeSuccess = success
        var afterFrame = getFrame(of: window)
        var check = afterFrame.map { checkFrame($0, against: position, size: size) }
        var bestMaxDiff = check?.maxDiff ?? CGFloat.greatestFiniteMagnitude
        var noProgressCount = 0

        if check?.isAcceptable != true {
            for retry in 1...maxRetryCount {
                rawSetSizeSuccess = applyMoveAndResizePass(window: window, to: position, size: size, waitTime: waitTime) || rawSetSizeSuccess
                usleep(retrySettleTime)
                setPosition(of: window, to: position)
                usleep(waitTime)
                afterFrame = getFrame(of: window)
                check = afterFrame.map { checkFrame($0, against: position, size: size) }

                if let check {
                    let improved = check.maxDiff < bestMaxDiff - progressTolerance
                    if improved {
                        bestMaxDiff = check.maxDiff
                        noProgressCount = 0
                    } else {
                        noProgressCount += 1
                    }

                    Log.debug(tag, "[move#\(logID)] retry \(retry)/\(maxRetryCount) frame=\(check.frame) diff=(x=\(check.xDiff), y=\(check.yDiff), w=\(check.widthDiff), h=\(check.heightDiff)) maxDiff=\(check.maxDiff) improved=\(improved) noProgress=\(noProgressCount)")
                    if check.isAcceptable {
                        break
                    }
                    if retry >= minimumRetryCount && noProgressCount >= maxNoProgressCount {
                        Log.debug(tag, "[move#\(logID)] retry stop: 差分改善が止まったため打ち切り retry=\(retry) bestMaxDiff=\(bestMaxDiff)")
                        break
                    }
                } else {
                    Log.warn(tag, "[move#\(logID)] retry \(retry)/\(maxRetryCount) frame=nil")
                }
            }
        }

        let actualSuccess = check?.isAcceptable == true

        // アプリケーション固有の最小サイズ制限等でどうしてもサイズが合わない場合の警告と判定
        if let check, !check.isAcceptable {
            if check.xDiff > 10 || check.yDiff > 10 {
                Log.warn(tag, "[move#\(logID)]   ⚠️ 移動要求位置と実際の位置が一致しません: 要求=\(position) 実際=\(check.frame.origin) (差: x=\(check.xDiff) y=\(check.yDiff))")
            }
            if check.widthDiff > 10 || check.heightDiff > 10 {
                Log.warn(tag, "[move#\(logID)]   ⚠️ リサイズ要求サイズと実際のサイズが一致しません（最小サイズ制限の可能性）: 要求=\(size) 実際=\(check.frame.size) (差: w=\(check.widthDiff) h=\(check.heightDiff))")
            }
        }
        
        Log.debug(tag, "[move#\(logID)] finish pid=\(pid) \"\(title)\" success=\(actualSuccess) rawSetSizeSuccess=\(rawSetSizeSuccess) isExpanding=\(isExpanding) → pos=\(position) size=\(size) (beforeFrame=\(beforeFrameForLog) afterFrame=\(afterFrame.map { "\($0)" } ?? "nil"))")
        return actualSuccess
    }

    /// ウィンドウを指定フレームに即時移動・リサイズ
    @discardableResult
    static func setFrame(_ frame: CGRect, to window: AXUIElement) -> Bool {
        return moveAndResize(window: window, to: frame.origin, size: frame.size)
    }

    @discardableResult
    static func setPositionOnly(of window: AXUIElement, to position: CGPoint) -> Bool {
        setPosition(of: window, to: position)
        usleep(20000)
        guard let after = getPosition(of: window) else { return false }
        let xDiff = abs(after.x - position.x)
        let yDiff = abs(after.y - position.y)
        if xDiff > 10 || yDiff > 10 {
            Log.warn(tag, "setPositionOnly: 位置補正が一致しません request=\(position) actual=\(after) diff=(\(xDiff), \(yDiff))")
            return false
        }
        return true
    }

    // MARK: - Title

    /// AXUIElement から PID を取得
    static func getPid(of window: AXUIElement) -> pid_t? {
        #if DEBUG
        if let mock = mockWindowPid {
            return mock
        }
        #endif
        var pid: pid_t = 0
        let result = AXUIElementGetPid(window, &pid)
        return result == .success ? pid : nil
    }

    /// ウィンドウのタイトルを取得
    static func getTitle(of window: AXUIElement) -> String? {
        #if DEBUG
        if let mock = mockWindowTitle {
            return mock
        }
        #endif
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
        #if DEBUG
        if let mock = mockWindowID {
            return mock
        }
        #endif
        var windowID: CGWindowID = 0
        let result = _AXUIElementGetWindow(window, &windowID)
        if result != .success {
            Log.warn(tag, "getWindowID: _AXUIElementGetWindow 失敗 error=\(result.rawValue) title=\"\(getTitle(of: window) ?? "")\"")
            return nil
        }
        return windowID
    }

    /// 現在のアクティブな操作スペース（仮想デスクトップ）上に表示されている CGWindowID セットを取得する
    static func getActiveSpaceWindowIDs() -> Set<CGWindowID> {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var ids = Set<CGWindowID>()
        for info in windowList {
            // 通常のアプリケーションウィンドウ（レイヤー0）のみを対象とする
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            if let wID = info[kCGWindowNumber as String] as? CGWindowID {
                ids.insert(wID)
            }
        }
        return ids
    }

    /// 指定されたモニター（NSScreen）の、現在アクティブな仮想スペースの UUID を取得する
    static func getActiveSpaceUUID(for screen: NSScreen) -> String? {
        let connection = CGSMainConnectionID()
        guard let displaySpaces = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else {
            return nil
        }
        
        // 1. ディスプレイの UUID 文字列を取得
        guard let targetDisplayUUID = screen.displayUUIDString else {
            // プライマリディスプレイ（displayID の UUID 取得失敗）のフォールバックとして、最初のディスプレイ情報を使う
            if let firstDisplay = displaySpaces.first,
               let currentSpace = firstDisplay["Current Space"] as? [String: Any],
               let uuid = currentSpace["uuid"] as? String,
               !uuid.isEmpty {
                return uuid
            }
            return nil
        }
        
        // 2. CGSCopyManagedDisplaySpaces の中から一致するディスプレイを探す
        for displayInfo in displaySpaces {
            guard let displayIDStr = displayInfo["Display Identifier"] as? String else {
                continue
            }
            
            if displayIDStr == targetDisplayUUID {
                if let currentSpace = displayInfo["Current Space"] as? [String: Any],
                   let uuid = currentSpace["uuid"] as? String,
                   !uuid.isEmpty {
                    return uuid
                }
            }
        }
        
        // 見つからない場合のフォールバック
        if let firstDisplay = displaySpaces.first,
           let currentSpace = firstDisplay["Current Space"] as? [String: Any],
           let uuid = currentSpace["uuid"] as? String,
           !uuid.isEmpty {
            return uuid
        }
        
        return nil
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

    /// 指定座標（AX座標系）にある最前面のウィンドウを取得する
    static func getWindow(at point: CGPoint) -> AXUIElement? {
        #if DEBUG
        if let mock = mockWindowAtPoint {
            return mock
        }
        #endif
        let systemWide = AXUIElementCreateSystemWide()
        var elementRef: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &elementRef)
        guard result == .success, let element = elementRef else {
            return nil
        }
        
        // 取得した要素がウィンドウでなければ、ウィンドウになるまで親要素を辿る
        var current: AXUIElement = element
        while true {
            var roleRef: CFTypeRef?
            let roleResult = AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            if roleResult == .success, let role = roleRef as? String {
                if role == kAXWindowRole as String {
                    return current
                }
            }
            
            // 親を辿る
            var parentRef: CFTypeRef?
            let parentResult = AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef)
            if parentResult == .success, let parent = parentRef {
                current = (parent as! AXUIElement)
            } else {
                break
            }
        }
        return nil
    }
}
