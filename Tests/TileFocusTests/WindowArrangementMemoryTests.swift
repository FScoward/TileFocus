import XCTest
@testable import TileFocus

final class WindowArrangementMemoryTests: XCTestCase {
    func testLayoutKeyIsStableRegardlessOfWindowOrder() {
        let browser = ManagedWindow(
            pid: 1001,
            windowID: 1,
            title: "Docs",
            appName: "Browser",
            bundleIdentifier: "com.example.browser",
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        )
        let editor = ManagedWindow(
            pid: 1002,
            windowID: 2,
            title: "Project",
            appName: "Editor",
            bundleIdentifier: "com.example.editor",
            frame: CGRect(x: 500, y: 0, width: 500, height: 400)
        )

        XCTAssertEqual(
            WindowArrangementSnapshot.layoutKey(for: [browser, editor], mode: .focus),
            WindowArrangementSnapshot.layoutKey(for: [editor, browser], mode: .focus)
        )
    }

    func testSnapshotMatchesSameVisibleWindowCombinationAfterPidAndWindowIDChange() {
        let original = [
            ManagedWindow(
                pid: 1001,
                windowID: 1,
                title: "Docs",
                appName: "Browser",
                bundleIdentifier: "com.example.browser",
                frame: CGRect(x: 0, y: 0, width: 500, height: 400)
            ),
            ManagedWindow(
                pid: 1002,
                windowID: 2,
                title: "Project",
                appName: "Editor",
                bundleIdentifier: "com.example.editor",
                frame: CGRect(x: 500, y: 0, width: 500, height: 400)
            )
        ]
        let relaunched = [
            ManagedWindow(
                pid: 2001,
                windowID: 21,
                title: "Project",
                appName: "Editor",
                bundleIdentifier: "com.example.editor",
                frame: .zero
            ),
            ManagedWindow(
                pid: 2002,
                windowID: 22,
                title: "Docs",
                appName: "Browser",
                bundleIdentifier: "com.example.browser",
                frame: .zero
            )
        ]

        let snapshot = WindowArrangementSnapshot(name: "Browser + Editor", mode: .focus, windows: original)

        XCTAssertTrue(snapshot.matches(windows: relaunched, mode: .focus))
        XCTAssertFalse(snapshot.matches(windows: relaunched, mode: .float))
        XCTAssertTrue(snapshot.matchesWindowCombination(windows: relaunched))
    }

    func testSnapshotDoesNotMatchDifferentWindowTitle() {
        let original = [
            ManagedWindow(
                pid: 1001,
                windowID: 1,
                title: "Docs",
                appName: "Browser",
                bundleIdentifier: "com.example.browser",
                frame: .zero
            )
        ]
        let differentPage = [
            ManagedWindow(
                pid: 1001,
                windowID: 1,
                title: "Mail",
                appName: "Browser",
                bundleIdentifier: "com.example.browser",
                frame: .zero
            )
        ]

        let snapshot = WindowArrangementSnapshot(name: "Browser", mode: .focus, windows: original)

        XCTAssertFalse(snapshot.matches(windows: differentPage, mode: .focus))
    }
}
