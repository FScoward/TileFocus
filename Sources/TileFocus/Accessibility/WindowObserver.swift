import Foundation
import AppKit

// MARK: - Delegate Protocol

protocol WindowObserverDelegate: AnyObject {
    /// 新規ウィンドウが作成された
    func windowObserver(_ observer: WindowObserver, didDetectWindowCreated window: ManagedWindow)
    /// ウィンドウが閉じられた
    func windowObserver(_ observer: WindowObserver, didDetectWindowClosed windowID: String)
    /// ウィンドウが移動された
    func windowObserver(_ observer: WindowObserver, didDetectWindowMoved window: ManagedWindow)
}

// MARK: - WindowObserver

/// AXObserver + NSWorkspace を使ってウィンドウイベントを監視するクラス
///
/// 注意点：
/// - AXObserver への強参照を保持する必要がある（解放されると通知が停止する）
/// - CFRunLoopAddSource で RunLoop に追加しないと通知が届かない
/// - システムワイドな「ウィンドウ作成」通知はない → 各アプリごとに AXObserver を作成
final class WindowObserver {

    // MARK: - Properties

    weak var delegate: WindowObserverDelegate?

    /// pid → AXObserver のマップ（強参照を保持）
    private var axObservers: [pid_t: AXObserver] = [:]

    /// NSWorkspace の通知 token
    private var workspaceObservers: [NSObjectProtocol] = []

    // MARK: - Public API

    /// 監視を開始する
    func startObserving() {
        // 既存の実行中アプリを監視
        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
            registerObserver(for: app)
        }

        // アプリの起動/終了を監視
        let launchToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.registerObserver(for: app)
        }

        let terminateToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.unregisterObserver(for: app.processIdentifier)
        }

        workspaceObservers = [launchToken, terminateToken]
        print("[WindowObserver] 監視開始: \(axObservers.count) アプリ")
    }

    /// 監視を停止する
    func stopObserving() {
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers = []

        for (pid, observer) in axObservers {
            let appElement = AXUIElementCreateApplication(pid)
            let src = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            _ = appElement // 参照を明示的に保持
        }
        axObservers = [:]
        print("[WindowObserver] 監視停止")
    }

    // MARK: - Private: AXObserver

    private func registerObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let axObserver = observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // 監視するイベント
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        for notification in notifications {
            AXObserverAddNotification(
                axObserver,
                appElement,
                notification as CFString,
                selfPtr
            )
        }

        // RunLoop に追加（必須）
        let source = AXObserverGetRunLoopSource(axObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        // 強参照を保持（解放されると通知が停止するため）
        axObservers[pid] = axObserver

        print("[WindowObserver] 登録: \(app.localizedName ?? "Unknown") (pid=\(pid))")
    }

    private func unregisterObserver(for pid: pid_t) {
        guard let observer = axObservers[pid] else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        axObservers.removeValue(forKey: pid)
        print("[WindowObserver] 登録解除: pid=\(pid)")
    }

    // MARK: - Event Handling

    fileprivate func handleNotification(
        observer: AXObserver,
        element: AXUIElement,
        notification: CFString
    ) {
        let notifName = notification as String

        switch notifName {
        case kAXWindowCreatedNotification:
            handleWindowCreated(element: element)

        case kAXUIElementDestroyedNotification:
            handleWindowClosed(element: element)

        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            handleWindowMoved(element: element)

        case kAXFocusedWindowChangedNotification:
            // フォーカス変更は WindowManager が NSWorkspace 経由で処理
            break

        default:
            break
        }
    }

    private func handleWindowCreated(element: AXUIElement) {
        guard let frame = AccessibilityHelper.getFrame(of: element) else { return }

        // PID を取得
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        let app = NSRunningApplication(processIdentifier: pid)
        let appName = app?.localizedName ?? "Unknown"
        let title = AccessibilityHelper.getTitle(of: element) ?? ""
        let windowID = AccessibilityHelper.getWindowID(of: element) ?? 0

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
        let windowID = AccessibilityHelper.getWindowID(of: element) ?? 0
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

/// C 関数として定義する AXObserver コールバック
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
