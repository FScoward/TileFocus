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
            SettingsPlaceholderView()
        }
    }
}

/// Phase 5 で本実装予定の設定画面プレースホルダー
private struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("設定")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Phase 5 で実装予定")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 400, height: 300)
    }
}
