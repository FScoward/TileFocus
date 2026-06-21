import Foundation

/// Focus Mode のレイアウト計算 (Centered Focus: 中央メイン、左右サブ)
///
/// フォーカスウィンドウを中央に大きく表示し、
/// 他のウィンドウを左右のサイドバーに交互に縦積みする。
///
/// ```
/// ┌──────┬─────────────────┬──────┐
/// │  W2  │                 │  W3  │
/// ├──────┤   フォーカス    ├──────┤
/// │  W4  │   ウィンドウ    │  W5  │
/// └──────┴─────────────────┴──────┘
/// ```
struct FocusLayout: Layout {
    var name: String { "Focus" }
    var gap: TilingGap = TilingGap(outer: 8, inner: 6)

    /// メインウィンドウの幅比率（全体の何 %）
    var mainWidthRatio: CGFloat = 0.55

    /// サイドバーの 1 ウィンドウあたりの最小高さ（px）
    /// これを下回る場合はウィンドウを表示しない（truncate）
    var minSideWindowHeight: CGFloat = 160

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }

        // 左側のサイドバー幅（StageSidebarView）を考慮して、タイリング領域を右にずらす
        let sidebarWidth: CGFloat = 180
        let adjustedMinX = screenFrame.minX + sidebarWidth
        let adjustedWidth = screenFrame.width - sidebarWidth

        let outer = gap.outer
        let inner = gap.inner
        let totalW = adjustedWidth  - outer * 2
        let totalH = screenFrame.height - outer * 2
        let startX = adjustedMinX + outer
        let startY = screenFrame.minY + outer

        if windowCount == 1 {
            // 1 枚: 全画面（ギャップあり）
            return [CGRect(x: startX, y: startY, width: totalW, height: totalH)]
        }

        let totalSideCount = windowCount - 1
        
        // 左右のサイドバーに割り振るウィンドウ数を計算
        // i = 1, 3, 5... (奇数番目のサブ) は左、i = 2, 4, 6... (偶数番目のサブ) は右
        var leftCount = 0
        var rightCount = 0
        for i in 1...totalSideCount {
            if i % 2 == 1 {
                leftCount += 1
            } else {
                rightCount += 1
            }
        }

        // メインウィンドウとサイドバーの幅・位置
        let mainW = (totalW - inner * 2) * mainWidthRatio
        let remainingW = (totalW - inner * 2) - mainW
        let sideW = remainingW / 2

        let leftX = startX
        let centerX = startX + sideW + inner
        let rightX = centerX + mainW + inner

        let mainFrame = CGRect(x: centerX, y: startY, width: mainW, height: totalH)

        // 左右の最大表示数を計算
        let maxSideCount = max(1, Int((totalH + inner) / (minSideWindowHeight + inner)))
        
        let leftDisplayCount = min(leftCount, maxSideCount)
        let rightDisplayCount = min(rightCount, maxSideCount)

        let leftH = leftDisplayCount > 0 ? (totalH - inner * CGFloat(leftDisplayCount - 1)) / CGFloat(leftDisplayCount) : 0
        let rightH = rightDisplayCount > 0 ? (totalH - inner * CGFloat(rightDisplayCount - 1)) / CGFloat(rightDisplayCount) : 0

        var frames = [mainFrame]
        
        var currentLeftIdx = 0
        var currentRightIdx = 0
        
        for i in 1...totalSideCount {
            if i % 2 == 1 {
                // 左サイドバー
                if currentLeftIdx < leftDisplayCount {
                    let sideY = startY + CGFloat(currentLeftIdx) * (leftH + inner)
                    frames.append(CGRect(x: leftX, y: sideY, width: sideW, height: leftH))
                    currentLeftIdx += 1
                }
            } else {
                // 右サイドバー
                if currentRightIdx < rightDisplayCount {
                    let sideY = startY + CGFloat(currentRightIdx) * (rightH + inner)
                    frames.append(CGRect(x: rightX, y: sideY, width: sideW, height: rightH))
                    currentRightIdx += 1
                }
            }
        }

        return frames
    }
}
