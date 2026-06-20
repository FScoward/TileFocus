import SwiftUI

@main
struct TileFocusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var windowManager = WindowManager.shared

    var body: some Scene {
        // メニューバーアイコン + ポップアップメニュー
        MenuBarExtra {
            MenuBarView()
                .environmentObject(windowManager)
        } label: {
            Image(systemName: "rectangle.3.group")
                .symbolRenderingMode(.hierarchical)
        }

        // 設定ウィンドウ（Cmd+, で開く）
        Settings {
            SettingsView()
        }
    }
}
