import Foundation

/// Focus Mode のレイアウト計算
///
/// フォーカスウィンドウを左 70% に大きく表示し、
/// 他のウィンドウを右サイドバーに縦積みする。
/// サイドウィンドウが多い場合は最大表示数を制限して 1 枚の最小高さを保つ。
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

    /// サイドバーの 1 ウィンドウあたりの最小高さ（px）
    /// これを下回る場合はウィンドウを表示しない（truncate）
    var minSideWindowHeight: CGFloat = 160

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

        // サイドバー領域
        let sideX = startX + mainW + inner
        let sideW = totalW - mainW - inner

        // サイドウィンドウの最大表示数を計算
        // 高さ minSideWindowHeight を下回らないよう制限
        let maxSideCount = max(1, Int((totalH + inner) / (minSideWindowHeight + inner)))
        let sideCount = min(windowCount - 1, maxSideCount)

        guard sideCount > 0 else {
            return [mainFrame]
        }

        let sideH = (totalH - inner * CGFloat(sideCount - 1)) / CGFloat(sideCount)

        var frames = [mainFrame]
        for i in 0..<sideCount {
            let sideY = startY + CGFloat(i) * (sideH + inner)
            frames.append(CGRect(x: sideX, y: sideY, width: sideW, height: sideH))
        }

        // 表示しきれなかったウィンドウは画面外（サイドバー末尾の直下）に格納
        // → そのまま返すだけ (frames.count < windowCount の場合、呼び出し側で break する)
        return frames
    }
}
