import Foundation
import AppKit

// MARK: - Delegate Protocol

protocol WindowObserverDelegate: AnyObject {
    /// 新規ウィンドウが作成された
    func windowObserver(_ observer: WindowObserver, didDetectWindowCreated window: ManagedWindow)
    /// ウィンドウが閉じられた
    func windowObserver(_ observer: WindowObserver, didDetectWindowClosed windowID: String)
    /// ウィンドウが移動・リサイズされた（ユーザー操作によるもの）
    func windowObserver(_ observer: WindowObserver, didDetectWindowMoved window: ManagedWindow)
    /// フォーカス（アクティブウィンドウ）が変更された
    func windowObserver(_ observer: WindowObserver, didDetectFocusChanged pid: pid_t, title: String)
    /// アプリが終了した
    func windowObserver(_ observer: WindowObserver, didDetectApplicationTerminated pid: pid_t)
}

// MARK: - WindowObserver

/// AXObserver + NSWorkspace を使ってウィンドウイベントを監視するクラス
///
/// 重要な設計上の注意点：
/// - kAXWindowCreatedNotification は app element に登録
/// - kAXWindowMovedNotification / Resized / Destroyed は window element に登録（app element では届かない）
/// - AXObserver への強参照を保持する必要がある
/// - CFRunLoopAddSource で RunLoop に追加しないと通知が届かない
final class WindowObserver {

    // MARK: - Properties

    weak var delegate: WindowObserverDelegate?

    /// pid → AXObserver のマップ（強参照を保持）
    private var axObservers: [pid_t: AXObserver] = [:]

    /// 移動通知を無視するフラグ（タイリング適用中は自分が動かした移動を無視する）
    var isTiling: Bool = false

    /// NSWorkspace の通知 token
    private var workspaceObservers: [NSObjectProtocol] = []

    /// AXUIElement から CGWindowID へのキャッシュ (閉じた時に一意に特定するため)
    private var windowIDCache: [AXElementWrapper: CGWindowID] = [:]

    // MARK: - Public API

    /// 監視を開始する
    func startObserving() {
        for app in NSWorkspace.shared.runningApplications
            where shouldMonitor(app) {
            registerObserver(for: app)
        }

        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            Log.info("WindowObserver", "アプリ起動: \(app.localizedName ?? "?") (pid=\(app.processIdentifier))")
            self?.registerObserver(for: app)
        }

        let terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Log.info("WindowObserver", "アプリ終了: \(app.localizedName ?? "?") (pid=\(pid))")
            self.delegate?.windowObserver(self, didDetectApplicationTerminated: pid)
            self.unregisterObserver(for: pid)
        }

        workspaceObservers = [launchToken, terminateToken]
        Log.info("WindowObserver", "監視開始: \(axObservers.count) アプリ")
    }

    /// 監視を停止する
    func stopObserving() {
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []
        for (_, observer) in axObservers {
            let src = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        axObservers = [:]
        Log.info("WindowObserver", "監視停止")
    }

    // MARK: - Private: Filter

    private func shouldMonitor(_ app: NSRunningApplication) -> Bool {
        // 自分自身は監視しない
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return false }
        // 通常の UI アプリのみ
        guard app.activationPolicy == .regular else { return false }
        return true
    }

    // MARK: - Private: AXObserver

    private func registerObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard axObservers[pid] == nil else { return }
        guard shouldMonitor(app) else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let axObserver = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // アプリレベルの通知: app element に登録
        let appLevelNotifications: [String] = [
            kAXWindowCreatedNotification,          // 新ウィンドウ
            kAXFocusedWindowChangedNotification,   // フォーカス変更
        ]
        for notification in appLevelNotifications {
            AXObserverAddNotification(axObserver, appElement, notification as CFString, selfPtr)
        }

        // ウィンドウレベルの通知: 既存の各 window element に登録
        registerWindowLevelNotifications(observer: axObserver, pid: pid, selfPtr: selfPtr)

        // RunLoop に追加（必須）
        let source = AXObserverGetRunLoopSource(axObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        // 強参照を保持
        axObservers[pid] = axObserver
        Log.info("WindowObserver", "登録: \(app.localizedName ?? "Unknown") (pid=\(pid)) windows=\(AccessibilityHelper.getWindows(for: pid).count)")
    }

    /// 既存の全ウィンドウにウィンドウレベルの通知を登録する
    private func registerWindowLevelNotifications(
        observer: AXObserver,
        pid: pid_t,
        selfPtr: UnsafeMutableRawPointer
    ) {
        let windows = AccessibilityHelper.getWindows(for: pid)
        let windowNotifications: [String] = [
            kAXUIElementDestroyedNotification,  // ウィンドウ閉じ
            kAXWindowMovedNotification,          // 移動
            kAXWindowResizedNotification,        // リサイズ
        ]
        for window in windows {
            // キャッシュに windowID を保存
            if let wID = AccessibilityHelper.getWindowID(of: window) {
                windowIDCache[AXElementWrapper(element: window)] = wID
            }
            for notification in windowNotifications {
                AXObserverAddNotification(observer, window, notification as CFString, selfPtr)
            }
        }
    }

    private func unregisterObserver(for pid: pid_t) {
        guard let observer = axObservers[pid] else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        axObservers.removeValue(forKey: pid)
        
        // キャッシュからこの pid のエントリをすべてクリーンアップ
        for key in windowIDCache.keys {
            var cachedPid: pid_t = 0
            AXUIElementGetPid(key.element, &cachedPid)
            if cachedPid == pid {
                windowIDCache.removeValue(forKey: key)
            }
        }
        
        Log.info("WindowObserver", "登録解除: pid=\(pid)")
    }

    // MARK: - Event Handling

    fileprivate func handleNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) {
        let notifName = notification as String
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let title = AccessibilityHelper.getTitle(of: element) ?? "?"

        switch notifName {
        case kAXWindowCreatedNotification:
            Log.info("WindowObserver", "kAXWindowCreated pid=\(pid) \"\(title)\"")
            handleWindowCreated(element: element, observer: observer)

        case kAXUIElementDestroyedNotification:
            Log.info("WindowObserver", "kAXUIElementDestroyed pid=\(pid) \"\(title)\"")
            handleWindowClosed(element: element)

        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            if isTiling {
                Log.debug("WindowObserver", "\(notifName) pid=\(pid) \"\(title)\" → isTiling=true スキップ")
                return
            }
            Log.debug("WindowObserver", "\(notifName) pid=\(pid) \"\(title)\" → handleWindowMoved")
            handleWindowMoved(element: element)

        case kAXFocusedWindowChangedNotification:
            Log.debug("WindowObserver", "kAXFocusedWindowChanged pid=\(pid) \"\(title)\"")
            if !isTiling {
                delegate?.windowObserver(self, didDetectFocusChanged: pid, title: title)
            }

        default:
            break
        }
    }

    private func handleWindowCreated(element: AXUIElement, observer: AXObserver) {
        // タイリング対象のウィンドウか厳密にチェック（ポップアップやメニュー等を除外）
        guard AccessibilityHelper.isTileable(element) else { return }

        guard let frame = AccessibilityHelper.getFrame(of: element) else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        // 新規ウィンドウにもウィンドウレベルの通知を登録
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let windowNotifications: [String] = [
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]
        for notification in windowNotifications {
            AXObserverAddNotification(observer, element, notification as CFString, selfPtr)
        }

        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "Unknown"
        let title = AccessibilityHelper.getTitle(of: element) ?? ""
        let windowID = AccessibilityHelper.getWindowID(of: element) ?? 0
        
        // キャッシュに保存
        if windowID != 0 {
            windowIDCache[AXElementWrapper(element: element)] = windowID
        }

        let window = ManagedWindow(
            pid: pid,
            windowID: windowID,
            title: title,
            appName: appName,
            bundleIdentifier: app?.bundleIdentifier,
            frame: frame
        )

        delegate?.windowObserver(self, didDetectWindowCreated: window)
    }

    private func handleWindowClosed(element: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        
        // 1. windowIDCache の中から、無効化された (属性取得がエラーになる) かつ pid が一致する wrapper を探す
        // (Destroyed 通知の element 自体は無効なため CFEqual 等のキー比較が失敗する対策)
        var closedWrapper: AXElementWrapper? = nil
        var closedWindowID: CGWindowID = 0
        
        for (wrapper, wID) in windowIDCache {
            var wrapperPid: pid_t = 0
            AXUIElementGetPid(wrapper.element, &wrapperPid)
            guard wrapperPid == pid else { continue }
            
            var value: CFTypeRef?
            let res = AXUIElementCopyAttributeValue(wrapper.element, kAXRoleAttribute as CFString, &value)
            if res != .success {
                // 属性コピーが失敗 ➔ このウィンドウが閉じられたと特定
                closedWrapper = wrapper
                closedWindowID = wID
                break
            }
        }
        
        let windowID: CGWindowID
        if let wrapper = closedWrapper {
            windowID = closedWindowID
            windowIDCache.removeValue(forKey: wrapper)
            Log.info("WindowObserver", "無効化されたAX要素を検出しウィンドウクローズを特定しました: id=\(pid)-\(windowID)")
        } else {
            // フォールバック
            let wrapper = AXElementWrapper(element: element)
            windowID = windowIDCache[wrapper] ?? 0
            windowIDCache.removeValue(forKey: wrapper)
        }
        
        let id = "\(pid)-\(windowID)"
        delegate?.windowObserver(self, didDetectWindowClosed: id)
    }

    private func handleWindowMoved(element: AXUIElement) {
        guard let frame = AccessibilityHelper.getFrame(of: element) else { return }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let app = NSRunningApplication(processIdentifier: pid)
        let windowID = AccessibilityHelper.getWindowID(of: element) ?? 0



        let window = ManagedWindow(
            pid: pid,
            windowID: windowID,
            title: AccessibilityHelper.getTitle(of: element) ?? "",
            appName: app?.localizedName ?? "Unknown",
            bundleIdentifier: app?.bundleIdentifier,
            frame: frame
        )

        delegate?.windowObserver(self, didDetectWindowMoved: window)
    }
}

// MARK: - AXObserver C Callback

private func axCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) {
    guard let ptr = userData else { return }
    let windowObserver = Unmanaged<WindowObserver>.fromOpaque(ptr).takeUnretainedValue()
    windowObserver.handleNotification(
        observer: observer,
        element: element,
        notification: notification
    )
}

/// AXUIElement を Dictionary のキーとして安全に扱うためのラッパー
struct AXElementWrapper: Hashable {
    let element: AXUIElement

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }

    static func == (lhs: AXElementWrapper, rhs: AXElementWrapper) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
