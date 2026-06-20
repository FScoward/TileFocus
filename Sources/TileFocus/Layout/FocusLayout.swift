import Foundation

/// Focus Mode のレイアウト計算
///
/// フォーカスウィンドウを左 70% に大きく表示し、
/// 他のウィンドウを右 28% にサイドバーとして縦積みする。
///
/// ```
/// ┌─────────────────┬──────┐
/// │                 │  W2  │
/// │                 ├──────┤
/// │   フォーカス     │  W3  │
/// │   ウィンドウ     ├──────┤
/// │                 │  W4  │
/// └─────────────────┴──────┘
/// ```
struct FocusLayout: Layout {
    var name: String { "Focus" }
    var gap: TilingGap = TilingGap(outer: 8, inner: 6)

    /// メインウィンドウの幅比率（全体の何 %）
    var mainWidthRatio: CGFloat = 0.70

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }

        let outer = gap.outer
        let inner = gap.inner
        let totalW = screenFrame.width  - outer * 2
        let totalH = screenFrame.height - outer * 2
        let startX = screenFrame.minX + outer
        let startY = screenFrame.minY + outer

        if windowCount == 1 {
            // 1 枚: 全画面（ギャップあり）
            return [CGRect(x: startX, y: startY, width: totalW, height: totalH)]
        }

        // メインウィンドウ（左側）
        let mainW = (totalW - inner) * mainWidthRatio
        let mainFrame = CGRect(x: startX, y: startY, width: mainW, height: totalH)

        // サイドバーウィンドウ（右側、縦積み）
        let sideX = startX + mainW + inner
        let sideW = totalW - mainW - inner
        let sideCount = windowCount - 1
        let sideH = (totalH - inner * CGFloat(sideCount - 1)) / CGFloat(sideCount)

        var frames = [mainFrame]
        for i in 0..<sideCount {
            let sideY = startY + CGFloat(i) * (sideH + inner)
            frames.append(CGRect(x: sideX, y: sideY, width: sideW, height: sideH))
        }

        return frames
    }
}
