import Foundation
import AppKit

/// 画面情報・座標変換のユーティリティ
///
/// === macOS 座標系の正しい理解 ===
///
/// AppKit (NSScreen):
/// - 原点はプライマリスクリーンの左下
/// - Y は上に増加
/// - 外付けモニターは Y がプライマリより大きい（上に配置の場合）
///
/// Accessibility API (AXUIElement):
/// - 原点は画面全体の左上（メニューバーの上）
/// - Y は下に増加
/// - 外付けモニターも同じ座標系を共有
///
/// 正しい変換:
///   ax.x = appkit.x
///   ax.y = primaryScreen.frame.height - appkit.y - appkit.height
///          ただし外付けモニターの場合は appkit.y が primaryH より大きい → ax.y はマイナスになる
///
struct ScreenManager {

    // MARK: - Screen Access

    /// プライマリスクリーン（AX 座標系の基準）
    var primaryScreen: NSScreen {
        NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// メインスクリーン（現在フォーカスされているスクリーン）
    var mainScreen: NSScreen {
        NSScreen.main ?? primaryScreen
    }

    /// 全スクリーン
    var allScreens: [NSScreen] {
        NSScreen.screens
    }

    // MARK: - Usable Frame

    /// メインスクリーンの使用可能フレーム（Accessibility 座標系: 左上原点）
    /// Dock・メニューバーを除いた領域
    var primaryVisibleFrameForAX: CGRect {
        visibleFrameInAX(for: mainScreen)
    }

    /// 指定スクリーンの使用可能フレーム（Accessibility 座標系）
    func visibleFrameInAX(for screen: NSScreen) -> CGRect {
        let vf = screen.visibleFrame
        return appKitToAX(vf)
    }

    // MARK: - Coordinate Conversion

    /// AppKit 座標 (左下原点) → Accessibility 座標 (左上原点) の正しい変換
    ///
    /// macOS の AX 座標系:
    /// - 原点: すべてのスクリーンを含む仮想デスクトップの左上
    /// - プライマリスクリーンの左上が (0, 0) ではなく、
    ///   プライマリスクリーンの frame.origin を基準にする
    ///
    /// 正確な変換式:
    ///   ax.x = appkit.x
    ///   ax.y = primaryScreen.frame.maxY - appkit.maxY
    ///        = primaryScreen.frame.height - (appkit.y + appkit.height)
    func appKitToAX(_ rect: CGRect) -> CGRect {
        let primaryMaxY = primaryScreen.frame.maxY
        let axY = primaryMaxY - rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: axY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Accessibility 座標 → AppKit 座標の変換
    func axToAppKit(_ rect: CGRect) -> CGRect {
        let primaryMaxY = primaryScreen.frame.maxY
        let appKitY = primaryMaxY - rect.maxY
        return CGRect(
            x: rect.origin.x,
            y: appKitY,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Legacy Compatibility

    /// 旧 API との互換性のために残す
    func convertToAXCoordinates(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        appKitToAX(rect)
    }

    func convertToAppKitCoordinates(_ rect: CGRect, in screen: NSScreen) -> CGRect {
        axToAppKit(rect)
    }

    // MARK: - Screen Detection

    /// 指定ポイントが属するスクリーンを返す（AppKit 座標系）
    func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// 指定ウィンドウフレームが最も多く重なるスクリーンを返す（Accessibility 座標系）
    func screen(containingAXFrame axFrame: CGRect) -> NSScreen {
        let appKitFrame = axToAppKit(axFrame)
        guard !NSScreen.screens.isEmpty else { return NSScreen.main ?? NSScreen.screens[0] }

        return NSScreen.screens.max { screenA, screenB in
            let areaA = screenA.frame.intersection(appKitFrame).area
            let areaB = screenB.frame.intersection(appKitFrame).area
            return areaA < areaB
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}

// MARK: - CGRect Extension

private extension CGRect {
    var area: CGFloat {
        guard width > 0 && height > 0 else { return 0 }
        return width * height
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSSDDeviceID")] as? CGDirectDisplayID
    }
    
    var identifier: String {
        if let id = displayID {
            return "\(id)"
        }
        return localizedName
    }

    var displayUUIDString: String? {
        guard let dID = displayID else { return nil }
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(dID) else { return nil }
        let cfUUID = uuidRef.takeRetainedValue()
        return CFUUIDCreateString(nil, cfUUID) as String?
    }
}
