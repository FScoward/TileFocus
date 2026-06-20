import Foundation
import AppKit

/// Accessibility 権限の確認と設定画面への誘導
enum PermissionChecker {

    /// アクセシビリティ権限が有効かどうか（プロンプトなし）
    static var isAccessibilityEnabled: Bool {
        AXIsProcessTrusted()
    }

    /// アクセシビリティ権限を確認し、必要に応じてシステムダイアログを表示
    /// - Returns: 権限が付与されている場合 `true`
    @discardableResult
    static func checkWithPrompt() -> Bool {
        let options: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定のアクセシビリティページを開く
    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// 権限が付与されるまで繰り返しポーリングする（最大試行回数あり）
    /// - Parameters:
    ///   - interval: ポーリング間隔（秒）
    ///   - maxRetries: 最大試行回数
    ///   - completion: 権限が付与された場合に呼ばれる
    static func waitForPermission(
        interval: TimeInterval = 1.0,
        maxRetries: Int = 60,
        completion: @escaping () -> Void
    ) {
        var retries = 0
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            retries += 1
            if AXIsProcessTrusted() {
                timer.invalidate()
                DispatchQueue.main.async { completion() }
            } else if retries >= maxRetries {
                timer.invalidate()
                print("[PermissionChecker] タイムアウト: アクセシビリティ権限が付与されませんでした")
            }
        }
    }
}
