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
}
