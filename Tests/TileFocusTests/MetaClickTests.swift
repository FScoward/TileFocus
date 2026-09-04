import XCTest
import AppKit
@testable import TileFocus

@MainActor
final class MetaClickTests: XCTestCase {
    private var originalDimmingEnabled = false
    private var originalMetaClickDimmingOpacity = 0.3
    private var originalMetaClickDimmingOpacityObject: Any?
    private var originalModesBySpace: [String: String] = [:]
    private var originalCrownSwapTrigger: CrownSwapTrigger = .clickOnly

    override func setUp() {
        super.setUp()
        originalDimmingEnabled = AppSettings.shared.isDimmingEnabled
        originalMetaClickDimmingOpacity = AppSettings.shared.metaClickDimmingOpacity
        originalMetaClickDimmingOpacityObject = UserDefaults.standard.object(forKey: "metaClickDimmingOpacity")
        originalModesBySpace = AppSettings.shared.modesBySpace
        originalCrownSwapTrigger = AppSettings.shared.crownSwapTrigger
        AppSettings.shared.isDimmingEnabled = false
        resetAccessibilityMocks()
    }

    override func tearDown() {
        AppSettings.shared.isDimmingEnabled = originalDimmingEnabled
        AppSettings.shared.metaClickDimmingOpacity = originalMetaClickDimmingOpacity
        if let originalMetaClickDimmingOpacityObject {
            UserDefaults.standard.set(originalMetaClickDimmingOpacityObject, forKey: "metaClickDimmingOpacity")
        } else {
            UserDefaults.standard.removeObject(forKey: "metaClickDimmingOpacity")
        }
        AppSettings.shared.modesBySpace = originalModesBySpace
        AppSettings.shared.crownSwapTrigger = originalCrownSwapTrigger
        resetAccessibilityMocks()
        super.tearDown()
    }

    func testControlCommandClickStartsTemporaryMetaFocusWithoutChangingDimmingSetting() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .float)
        XCTAssertEqual(windowManager.masterWindowID, target.id)
        XCTAssertEqual(windowManager.focusedWindowID, target.id)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testControlCommandClickOnManualFloatStartsMetaFocusAndSecondSameClickTurnsItOff() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        windowManager.switchMode(to: .float)
        mockAccessibilityWindow(for: target)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(windowManager.currentMode, .float)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
        XCTAssertEqual(windowManager.masterWindowID, target.id)

        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .off)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertNil(windowManager.masterWindowID)
        XCTAssertNil(windowManager.focusedWindowID)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testMetaClickOnDifferentWindowKeepsFloatAndChangesTarget() async throws {
        let windowManager = makeWindowManager()
        let first = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "First",
            appName: "FirstApp",
            bundleIdentifier: "com.example.first",
            frame: .zero
        )
        let second = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Second",
            appName: "SecondApp",
            bundleIdentifier: "com.example.second",
            frame: .zero
        )
        windowManager.updateManagedWindows([first, second])

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        mockAccessibilityWindow(for: first)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        mockAccessibilityWindow(for: second)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .float)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
        XCTAssertEqual(windowManager.masterWindowID, second.id)
        XCTAssertEqual(windowManager.focusedWindowID, second.id)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testControlCommandClickDoesNotOverwriteNormalDimmingSetting() async throws {
        AppSettings.shared.isDimmingEnabled = true

        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .float)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
        XCTAssertTrue(AppSettings.shared.isDimmingEnabled)
    }

    func testMetaFocusDimmingTargetsMasterInsteadOfFocusedWindow() {
        XCTAssertEqual(
            DimmingManager.dimmingTargetWindowID(
                isMetaClickFocusActive: true,
                focusedWindowID: "focused",
                masterWindowID: "master"
            ),
            "master"
        )
    }

    func testNormalDimmingStillTargetsFocusedWindow() {
        XCTAssertEqual(
            DimmingManager.dimmingTargetWindowID(
                isMetaClickFocusActive: false,
                focusedWindowID: "focused",
                masterWindowID: "master"
            ),
            "focused"
        )
    }

    func testMetaFocusUsesDedicatedDimmingOpacity() {
        XCTAssertEqual(
            DimmingManager.opacityForCurrentState(
                isMetaClickFocusActive: true,
                normalOpacity: 0.2,
                metaClickOpacity: 0.7
            ),
            0.7
        )
    }

    func testNormalDimmingUsesNormalOpacity() {
        XCTAssertEqual(
            DimmingManager.opacityForCurrentState(
                isMetaClickFocusActive: false,
                normalOpacity: 0.2,
                metaClickOpacity: 0.7
            ),
            0.2
        )
    }

    func testMetaClickDimmingOpacityDefaultsTo30PercentWhenUnset() {
        let suiteName = "MetaClickTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(defaults.object(forKey: "metaClickDimmingOpacity"))
        XCTAssertEqual(AppSettings.loadMetaClickDimmingOpacity(from: defaults), 0.3)
    }

    func testMetaClickDimmingOpacityPersistsToUserDefaults() {
        let value = 0.65
        AppSettings.shared.metaClickDimmingOpacity = value

        XCTAssertEqual(
            UserDefaults.standard.double(forKey: "metaClickDimmingOpacity"),
            value
        )
    }

    func testCommandOnlyClickDoesNothing() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .off)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertNil(windowManager.masterWindowID)
        XCTAssertNil(windowManager.focusedWindowID)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testControlCommandClickWithShiftDoesNothing() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control, .shift]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .off)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertNil(windowManager.masterWindowID)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testCommandClickOnUnmanagedWindowDoesNothing() async throws {
        let windowManager = makeWindowManager()
        let managed = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "Managed",
            appName: "ManagedApp",
            bundleIdentifier: "com.example.managed",
            frame: .zero
        )
        let unmanaged = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Unmanaged",
            appName: "UnmanagedApp",
            bundleIdentifier: "com.example.unmanaged",
            frame: .zero
        )
        windowManager.updateManagedWindows([managed])
        mockAccessibilityWindow(for: unmanaged)

        let hotKeyManager = HotKeyManager(windowManager: windowManager)
        hotKeyManager.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .off)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertNil(windowManager.masterWindowID)
        XCTAssertNil(windowManager.focusedWindowID)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testExistingFocusClickHandlerLeavesControlCommandClickForGlobalHandler() async throws {
        let windowManager = makeWindowManager()
        let currentMaster = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "Current",
            appName: "CurrentApp",
            bundleIdentifier: "com.example.current",
            frame: .zero
        )
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)
        windowManager.switchMode(to: .focus)
        windowManager.updateManagedWindows([currentMaster, target])
        windowManager.setMasterWindow(to: currentMaster.id)
        mockAccessibilityWindow(for: target)

        controller.handleMouseClick(event: mouseDown(modifiers: [.command, .control]), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.currentMode, .focus)
        XCTAssertEqual(windowManager.masterWindowID, currentMaster.id)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testNormalClickWhileMetaFocusIsActiveDoesNotChangeMasterOrFocus() async throws {
        AppSettings.shared.crownSwapTrigger = .clickOnly

        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        let controller = FocusModeController(windowManager: windowManager)
        windowManager.setFocusControllerForTesting(controller)

        let first = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "First",
            appName: "FirstApp",
            bundleIdentifier: "com.example.first",
            frame: .zero
        )
        let second = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Second",
            appName: "SecondApp",
            bundleIdentifier: "com.example.second",
            frame: .zero
        )
        windowManager.updateManagedWindows([first, second])

        mockAccessibilityWindow(for: first)
        windowManager.focusWindowAtMetaClick(at: .zero)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
        XCTAssertEqual(windowManager.masterWindowID, first.id)
        XCTAssertEqual(windowManager.focusedWindowID, first.id)

        mockAccessibilityWindow(for: second)
        controller.handleMouseClick(event: mouseDown(modifiers: []), at: .zero)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(windowManager.masterWindowID, first.id)
        XCTAssertEqual(windowManager.focusedWindowID, first.id)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)
    }

    func testLeavingFloatByModeSwitchClearsTemporaryMetaFocus() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        windowManager.focusWindowAtMetaClick(at: .zero)
        XCTAssertEqual(windowManager.currentMode, .float)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)

        windowManager.switchMode(to: .focus)

        XCTAssertEqual(windowManager.currentMode, .focus)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    func testRestoringAnotherModeClearsTemporaryMetaFocus() async throws {
        let windowManager = makeWindowManager()
        let target = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Target",
            appName: "TargetApp",
            bundleIdentifier: "com.example.target",
            frame: .zero
        )
        windowManager.updateManagedWindows([target])
        mockAccessibilityWindow(for: target)

        let spaceKey = "meta-click-focus-test-space"
        AppSettings.shared.setMode(.focus, forSpaceKey: spaceKey)
        windowManager.focusWindowAtMetaClick(at: .zero)
        XCTAssertTrue(windowManager.isMetaClickFocusActive)

        windowManager.restoreModeForTesting(spaceKey: spaceKey)

        XCTAssertEqual(windowManager.currentMode, .focus)
        XCTAssertFalse(windowManager.isMetaClickFocusActive)
        XCTAssertFalse(AppSettings.shared.isDimmingEnabled)
    }

    private func makeWindowManager() -> WindowManager {
        let windowManager = WindowManager()
        windowManager.isTestingMode = true
        windowManager.setFocusControllerForTesting(FocusModeController(windowManager: windowManager))
        return windowManager
    }

    private func mouseDown(modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }

    private func mockAccessibilityWindow(for window: ManagedWindow) {
        AccessibilityHelper.mockWindowAtPoint = AXUIElementCreateSystemWide()
        AccessibilityHelper.mockWindowID = window.windowID
        AccessibilityHelper.mockWindowPid = window.pid
        AccessibilityHelper.mockWindowTitle = window.title
    }

    private func resetAccessibilityMocks() {
        AccessibilityHelper.mockWindowAtPoint = nil
        AccessibilityHelper.mockWindowID = nil
        AccessibilityHelper.mockWindowPid = nil
        AccessibilityHelper.mockWindowTitle = nil
    }
}
