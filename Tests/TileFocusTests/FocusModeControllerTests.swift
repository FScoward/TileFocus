import XCTest
@testable import TileFocus

@MainActor
final class FocusModeControllerTests: XCTestCase {
    
    private var originalTrigger: CrownSwapTrigger = .clickOnly
    
    override func setUp() {
        super.setUp()
        // アプリケーション全体の設定だけ退避
        originalTrigger = AppSettings.shared.crownSwapTrigger
    }
    
    override func tearDown() {
        AppSettings.shared.crownSwapTrigger = originalTrigger
        super.tearDown()
    }
    
    /// clickOnly設定のとき、通常クリック（フォーカス変更）で自動的にマスター（王冠）が切り替わることをテスト
    func testClickOnlySwapsMasterOnFocusChange() async throws {
        // 新しい孤立した WindowManager インスタンスを作成
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        // 設定を clickOnly にする
        AppSettings.shared.crownSwapTrigger = .clickOnly
        
        // テスト用 FocusModeController を生成してインジェクト
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        // テスト用のダミーウィンドウを登録
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 初期状態として WindowA をマスター & フォーカスに設定
        windowManager.setMasterWindow(to: windowA.id)
        
        // applyLayoutの0.25秒のディレイを考慮して多めに待機
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        XCTAssertEqual(windowManager.masterWindowID, windowA.id)
        XCTAssertEqual(windowManager.focusedWindowID, windowA.id)
        
        // WindowB にフォーカスを変更（通常クリックやイベントによる変更をシミュレート）
        windowManager.windowObserver(WindowObserver(), didDetectFocusChanged: windowB.pid, title: windowB.title)
        
        // 処理の完了を待機
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        // clickOnly なので、フォーカス変更に伴いマスターも WindowB に自動変更されるはず
        XCTAssertEqual(windowManager.focusedWindowID, windowB.id)
        XCTAssertEqual(windowManager.masterWindowID, windowB.id, "clickOnly設定時はフォーカス変更に伴いマスター（王冠）が切り替わるべきです")
    }
    
    /// ctrlShiftClick設定のとき、通常フォーカス変更ではマスター（王冠）が切り替わらないことをテスト
    func testCtrlShiftClickDoesNotSwapMasterOnFocusChange() async throws {
        // 新しい孤立した WindowManager インスタンスを作成
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        // 設定を ctrlShiftClick にする
        AppSettings.shared.crownSwapTrigger = .ctrlShiftClick
        
        // テスト用 FocusModeController を生成してインジェクト
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        // テスト用のダミーウィンドウを登録
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 初期状態として WindowA をマスター & フォーカスに設定
        windowManager.setMasterWindow(to: windowA.id)
        
        // applyLayoutの0.25秒のディレイを考慮して多めに待機
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        XCTAssertEqual(windowManager.masterWindowID, windowA.id)
        XCTAssertEqual(windowManager.focusedWindowID, windowA.id)
        
        // WindowB に通常クリックによるフォーカス変更をシミュレート
        windowManager.windowObserver(WindowObserver(), didDetectFocusChanged: windowB.pid, title: windowB.title)
        
        // 処理の完了を待機
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        // ctrlShiftClick なので、フォーカスは WindowB に切り替わるが、マスターは WindowA のまま維持されるはず
        XCTAssertEqual(windowManager.focusedWindowID, windowB.id)
        XCTAssertEqual(windowManager.masterWindowID, windowA.id, "ctrlShiftClick設定時は通常フォーカス変更ではマスターが維持されるべきです")
    }
    
    /// ctrlShiftClick設定のとき、Control+Shift+クリックを検出するとマスター（王冠）が切り替わることをテスト
    func testCtrlShiftClickSwapsMaster() async throws {
        // 新しい孤立した WindowManager インスタンスを作成
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        // 設定を ctrlShiftClick にする
        AppSettings.shared.crownSwapTrigger = .ctrlShiftClick
        
        // テスト用 FocusModeController を生成してインジェクト
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        // テスト用のダミーウィンドウを登録
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 初期状態として WindowA をマスター & フォーカスに設定
        windowManager.setMasterWindow(to: windowA.id)
        
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        XCTAssertEqual(windowManager.masterWindowID, windowA.id)
        XCTAssertEqual(windowManager.focusedWindowID, windowA.id)
        
        // AccessibilityHelper のモック設定
        let dummyAXWindow = AXUIElementCreateSystemWide()
        AccessibilityHelper.mockWindowAtPoint = dummyAXWindow
        AccessibilityHelper.mockWindowID = 2 // WindowB の windowID は 2
        AccessibilityHelper.mockWindowPid = 1002 // WindowB の pid は 1002
        AccessibilityHelper.mockWindowTitle = "AppB"
        
        defer {
            AccessibilityHelper.mockWindowAtPoint = nil
            AccessibilityHelper.mockWindowID = nil
            AccessibilityHelper.mockWindowPid = nil
            AccessibilityHelper.mockWindowTitle = nil
        }
        
        // Control + Shift を押したクリックイベントをシミュレート
        let clickEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        
        // クリックハンドラを呼び出し
        controller.handleMouseClick(event: clickEvent, at: .zero)
        
        // 処理の完了を待機
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        // Control+Shift+クリックなので、マスターも WindowB に切り替わるはず
        XCTAssertEqual(windowManager.masterWindowID, windowB.id, "ctrlShiftClick設定時でも、Control+Shift+クリックを行った場合はマスター（王冠）が切り替わるべきです")
    }
    
    /// 仮想スペース切り替え中にフォーカス変更イベントを検出しても、マスターが勝手に切り替わらないことをテスト
    func testSpaceSwitchingPreventsMasterOverride() async throws {
        // 新しい孤立した WindowManager インスタンスを作成
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        // 設定を clickOnly にする（通常ならフォーカス変更でマスターが変わる設定）
        AppSettings.shared.crownSwapTrigger = .clickOnly
        
        // テスト用 FocusModeController を生成してインジェクト
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        // テスト用のダミーウィンドウを登録
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 初期状態として WindowA をマスター & フォーカスに設定
        windowManager.setMasterWindow(to: windowA.id)
        
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        XCTAssertEqual(windowManager.masterWindowID, windowA.id)
        XCTAssertEqual(windowManager.focusedWindowID, windowA.id)
        
        // スペース切り替え中フラグを立てる
        windowManager.isSpaceSwitching = true
        
        // WindowB にフォーカスが切り替わったイベントを流す（スペース遷移時のOSによるフォーカス移動を想定）
        windowManager.windowObserver(WindowObserver(), didDetectFocusChanged: windowB.pid, title: windowB.title)
        
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4秒待機
        
        // clickOnly 設定だが、isSpaceSwitching = true なのでフォーカス変更イベントは無視され、
        // マスターは WindowA のまま維持されているはず
        XCTAssertEqual(windowManager.masterWindowID, windowA.id, "スペース切り替え中はフォーカス変更によるマスター上書きが無視されるべきです")
        
        // スペース切り替え完了
        windowManager.isSpaceSwitching = false
    }

    /// 仮想スペース切り替え中に遅延した移動通知が届いても、管理中のフレームを上書きしないことをテスト
    func testSpaceSwitchingIgnoresWindowMovedFrameUpdate() async throws {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true

        let originalFrame = CGRect(x: 10, y: 20, width: 300, height: 400)
        let movedFrame = CGRect(x: 500, y: 600, width: 700, height: 800)
        let window = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "AppA",
            appName: "AppA",
            bundleIdentifier: "com.AppA",
            frame: originalFrame
        )
        let movedWindow = ManagedWindow(
            pid: window.pid,
            windowID: window.windowID,
            title: window.title,
            appName: window.appName,
            bundleIdentifier: window.bundleIdentifier,
            frame: movedFrame
        )

        windowManager.updateManagedWindows([window])
        windowManager.isSpaceSwitching = true

        windowManager.windowObserver(WindowObserver(), didDetectWindowMoved: movedWindow)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.managedWindows.first?.frame, originalFrame, "スペース切り替え中の移動通知でフレームキャッシュが上書きされるべきではありません")

        windowManager.isSpaceSwitching = false
    }

    /// 仮想スペース切り替え中に予約済みレイアウトが実行されても、マスター自動割り当てなどの再配置前処理を行わないことをテスト
    func testSpaceSwitchingSkipsApplyLayoutSideEffects() async throws {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true

        AppSettings.shared.crownSwapTrigger = .clickOnly

        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)

        windowManager.switchMode(to: .focus)

        let window = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "AppA",
            appName: "AppA",
            bundleIdentifier: "com.AppA",
            frame: .zero
        )
        windowManager.updateManagedWindows([window])
        windowManager.isSpaceSwitching = true

        controller.applyLayout()

        XCTAssertNil(windowManager.masterWindowID, "スペース切り替え中の applyLayout はマスターを自動設定するべきではありません")

        windowManager.isSpaceSwitching = false
    }
    
    /// ctrlShiftClick設定のとき、マスターが未設定(nil)の状態でレイアウトが走っても、自動的にマスターが設定されないことをテスト
    func testCtrlShiftClickDoesNotAssignMasterAutomaticallyIfNil() async throws {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        AppSettings.shared.crownSwapTrigger = .ctrlShiftClick
        
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        windowManager.updateManagedWindows([windowA, windowB])
        
        // applyLayout() を直接呼び出すことでレイアウト計算を実行
        controller.applyLayout()
        
        try await Task.sleep(nanoseconds: 400_000_000)
        
        // ctrlShiftClick なので、applyLayout しても masterWindowID は nil のままであるべき
        XCTAssertNil(windowManager.masterWindowID, "ctrlShiftClick設定時はマスターがnilの場合に自動設定されるべきではありません")
    }
    
    /// ctrlShiftClick設定のとき、マスターウィンドウが消失（クローズ）した際、自動的に他のウィンドウにマスターが移譲されず nil になることをテスト
    func testCtrlShiftClickClearsMasterIfMasterWindowDisappears() async throws {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        AppSettings.shared.crownSwapTrigger = .ctrlShiftClick
        
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 初期状態として WindowA をマスターに設定
        windowManager.setMasterWindow(to: windowA.id)
        try await Task.sleep(nanoseconds: 400_000_000)
        
        XCTAssertEqual(windowManager.masterWindowID, windowA.id)
        
        // WindowA が閉じられた（リストから削除してクローズイベント発火）
        windowManager.updateManagedWindows([windowB])
        controller.handleWindowClosed(id: windowA.id)
        
        try await Task.sleep(nanoseconds: 400_000_000)
        
        // ctrlShiftClick なので、マスターウィンドウが閉じられた場合、自動移譲されず nil になるべき
        XCTAssertNil(windowManager.masterWindowID, "ctrlShiftClick設定時はマスターが閉じられた際に自動移譲されるべきではありません")
    }
    
    /// ctrlShiftClick設定のとき、マスターが未設定(nil)の状態でフォーカスが切り替わっても、自動的にマスターが設定されないことをテスト
    func testCtrlShiftClickDoesNotAssignMasterOnFocusChangeIfNil() async throws {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        
        AppSettings.shared.crownSwapTrigger = .ctrlShiftClick
        
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        
        windowManager.switchMode(to: .focus)
        
        let windowA = ManagedWindow(pid: 1001, windowID: 1, title: "AppA", appName: "AppA", bundleIdentifier: "com.AppA", frame: .zero)
        let windowB = ManagedWindow(pid: 1002, windowID: 2, title: "AppB", appName: "AppB", bundleIdentifier: "com.AppB", frame: .zero)
        windowManager.updateManagedWindows([windowA, windowB])
        
        // 最初はマスターが未設定 (nil) とする
        XCTAssertNil(windowManager.masterWindowID)
        
        // WindowA にフォーカスが変更されたイベントをシミュレート
        windowManager.windowObserver(WindowObserver(), didDetectFocusChanged: windowA.pid, title: windowA.title)
        
        try await Task.sleep(nanoseconds: 400_000_000)
        
        // ctrlShiftClick なので、フォーカスが切り替わってもマスターは nil のままであるべき
        XCTAssertNil(windowManager.masterWindowID, "ctrlShiftClick設定時はマスターがnilの状態でフォーカスが変更されても自動的にマスターが設定されるべきではありません")
        
        // さらに WindowB にフォーカスが変更されても nil のままであるべき
        windowManager.windowObserver(WindowObserver(), didDetectFocusChanged: windowB.pid, title: windowB.title)
        
        try await Task.sleep(nanoseconds: 400_000_000)
        
        XCTAssertNil(windowManager.masterWindowID)
    }
}
