import Foundation
import AppKit

/// 画面情報・座標変換のユーティリティ
///
/// 座標系の違いに注意：
/// - Accessibility API: 左上原点（y は下に増加）
/// - AppKit (NSScreen): 左下原点（y は上に増加）
struct ScreenManager {

    // MARK: - Screen Access

    /// プライマリスクリーン（メインモニター）
    var primaryScreen: NSScreen? {
        NSScreen.main
    }

    /// 全スクリーン
    var allScreens: [NSScreen] {
        NSScreen.screens
    }

    // MARK: - Usable Frame

    /// メインスクリーンの使用可能フレーム（Dock・メニューバー除外、AppKit 座標系）
    var primaryVisibleFrame: CGRect {
        NSScreen.main?.visibleFrame ?? .zero
    }

    /// メインスクリーンの使用可能フレーム（Accessibility 座標系: 左上原点）
    var primaryVisibleFrameForAX: CGRect {
        guard let screen = NSScreen.main else { return .zero }
        return convertToAXCoordinates(screen.visibleFrame, in: screen)
    }

    /// 指定スクリーンの使用可能フレーム（Accessibility 座標系）
    func visibleFrameForAX(screen: NSScreen) -> CGRect {
        convertToAXCoordinates(screen.visibleFrame, in: screen)
    }

    // MARK: - Coordinate Conversion

    /// AppKit 座標（左下原点）→ Accessibility 座標（左上原点）変換
    ///
    /// 変換式:
    /// - axX = nsX
    /// - axY = screenHeight - nsY - windowHeight
    func convertToAXCoordinates(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        // NSScreen.frame は左下原点なので、全スクリーン高さからの変換が必要
        // プライマリスクリーンの高さを基準にする
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height

        let axY = primaryScreenHeight - rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: axY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Accessibility 座標（左上原点）→ AppKit 座標（左下原点）変換
    func convertToAppKitCoordinates(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let nsY = primaryScreenHeight - rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: nsY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Screen Detection

    /// 指定ポイントが属するスクリーンを返す（AppKit 座標系）
    func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 指定ウィンドウフレームが最も多く重なるスクリーンを返す（Accessibility 座標系）
    func screen(containingAXFrame frame: CGRect) -> NSScreen {
        guard !NSScreen.screens.isEmpty else { return NSScreen.main! }

        return NSScreen.screens.max { screenA, screenB in
            let areaA = screenA.frame.intersection(
                convertToAppKitCoordinates(frame, in: screenA)
            ).area
            let areaB = screenB.frame.intersection(
                convertToAppKitCoordinates(frame, in: screenB)
            ).area
            return areaA < areaB
        } ?? NSScreen.main!
    }
}

// MARK: - CGRect Extension

private extension CGRect {
    var area: CGFloat { width * height }
}
