import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock アイコンを非表示にしてメニューバーアプリとして動作
        NSApp.setActivationPolicy(.accessory)

        // Accessibility 権限チェック
        checkAccessibilityPermission()
    }

    private func checkAccessibilityPermission() {
        if PermissionChecker.isAccessibilityEnabled {
            // 権限あり → ウィンドウ監視を開始
            WindowManager.shared.startObserving()
        } else {
            // 権限なし → アラート表示してシステム設定を促す
            showPermissionAlert()
            
            // アプリを終了させず、権限が許可されるのを繰り返しチェック（3分間）
            PermissionChecker.waitForPermission(interval: 1.0, maxRetries: 180) {
                print("[AppDelegate] アクセシビリティ権限が付与されました。ウィンドウ監視を開始します。")
                WindowManager.shared.startObserving()
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "アクセシビリティ権限が必要です"
        alert.informativeText = """
            TileFocus はウィンドウを操作するために \
            アクセシビリティ権限が必要です。
            
            システム設定 → プライバシーとセキュリティ → \
            アクセシビリティ で TileFocus を許可してください。
            """
        alert.addButton(withTitle: "システム設定を開く")
        alert.addButton(withTitle: "後で")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionChecker.openAccessibilitySettings()
        }
    }
}
