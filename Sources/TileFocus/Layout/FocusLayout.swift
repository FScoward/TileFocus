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
    var gap: TilingGap { AppSettings.shared.tilingGap }

    /// メインウィンドウの幅比率（全体の何 %）
    var mainWidthRatio: CGFloat {
        CGFloat(AppSettings.shared.mainWidthRatio)
    }

    /// 中央2分割レイアウトの際のメインウィンドウの合計幅比率（全体の何 %）
    var splitMainWidthRatio: CGFloat {
        CGFloat(AppSettings.shared.mainWidthRatio)
    }

    /// サイドバーの 1 ウィンドウあたりの最小高さ（px）
    /// これを下回る場合はウィンドウを表示しない（truncate）
    var minSideWindowHeight: CGFloat = 160

    /// フォーカスのスタイル（中央メイン、左メイン、右メイン）
    var style: FocusStyle = .centered

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

        let totalSideCount = windowCount - 1

        switch style {
        case .centered:
            // 従来の左右配置（Centered Focus）
            var leftCount = 0
            var rightCount = 0
            for i in 1...totalSideCount {
                if i % 2 == 1 {
                    leftCount += 1
                } else {
                    rightCount += 1
                }
            }

            let mainW = (totalW - inner * 2) * mainWidthRatio
            let remainingW = (totalW - inner * 2) - mainW
            let sideW = remainingW / 2

            let leftX = startX
            let centerX = startX + sideW + inner
            let rightX = centerX + mainW + inner

            let mainFrame = CGRect(x: centerX, y: startY, width: mainW, height: totalH)

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
                    if currentLeftIdx < leftDisplayCount {
                        let sideY = startY + CGFloat(currentLeftIdx) * (leftH + inner)
                        frames.append(CGRect(x: leftX, y: sideY, width: sideW, height: leftH))
                        currentLeftIdx += 1
                    } else {
                        frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                    }
                } else {
                    if currentRightIdx < rightDisplayCount {
                        let sideY = startY + CGFloat(currentRightIdx) * (rightH + inner)
                        frames.append(CGRect(x: rightX, y: sideY, width: sideW, height: rightH))
                        currentRightIdx += 1
                    } else {
                        frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                    }
                }
            }
            return frames

        case .leftMain:
            // 左メイン、右サブ
            let mainW = (totalW - inner) * mainWidthRatio
            let sideW = (totalW - inner) - mainW

            let mainFrame = CGRect(x: startX, y: startY, width: mainW, height: totalH)
            let sideX = startX + mainW + inner

            let maxSideCount = max(1, Int((totalH + inner) / (minSideWindowHeight + inner)))
            let sideDisplayCount = min(totalSideCount, maxSideCount)
            let sideH = sideDisplayCount > 0 ? (totalH - inner * CGFloat(sideDisplayCount - 1)) / CGFloat(sideDisplayCount) : 0

            var frames = [mainFrame]
            for i in 0..<totalSideCount {
                if i < sideDisplayCount {
                    let sideY = startY + CGFloat(i) * (sideH + inner)
                    frames.append(CGRect(x: sideX, y: sideY, width: sideW, height: sideH))
                } else {
                    frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                }
            }
            return frames

        case .rightMain:
            // 右メイン、左サブ
            let mainW = (totalW - inner) * mainWidthRatio
            let sideW = (totalW - inner) - mainW

            let sideX = startX
            let mainX = startX + sideW + inner

            let mainFrame = CGRect(x: mainX, y: startY, width: mainW, height: totalH)

            let maxSideCount = max(1, Int((totalH + inner) / (minSideWindowHeight + inner)))
            let sideDisplayCount = min(totalSideCount, maxSideCount)
            let sideH = sideDisplayCount > 0 ? (totalH - inner * CGFloat(sideDisplayCount - 1)) / CGFloat(sideDisplayCount) : 0

            var frames = [mainFrame]
            for i in 0..<totalSideCount {
                if i < sideDisplayCount {
                    let sideY = startY + CGFloat(i) * (sideH + inner)
                    frames.append(CGRect(x: sideX, y: sideY, width: sideW, height: sideH))
                } else {
                    frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                }
            }
            return frames

        case .splitCentered:
            // 中央を2分割（メイン2枚）、他を両サイドに交互に配置
            if windowCount == 1 {
                // 1枚なら全画面
                return [CGRect(x: startX, y: startY, width: totalW, height: totalH)]
            } else if windowCount == 2 {
                // 2枚なら中央に2分割（サイドなしで画面いっぱいに広げる）
                let mainW = (totalW - inner) / 2
                return [
                    CGRect(x: startX, y: startY, width: mainW, height: totalH),
                    CGRect(x: startX + mainW + inner, y: startY, width: mainW, height: totalH)
                ]
            }

            // 3枚以上の場合
            let totalSideCount = windowCount - 2
            var leftCount = 0
            var rightCount = 0
            for i in 1...totalSideCount {
                if i % 2 == 1 {
                    leftCount += 1
                } else {
                    rightCount += 1
                }
            }

            // 最小幅を 260px に保証する
            let minSideWidth: CGFloat = 260
            let mainTotalW = (totalW - inner * 2) * splitMainWidthRatio
            let remainingW = (totalW - inner * 2) - mainTotalW
            var sideW = remainingW / 2
            
            if sideW < minSideWidth {
                sideW = minSideWidth
            }
            
            let actualMainTotalW = totalW - inner * 2 - sideW * 2
            let mainEachW = max(100, (actualMainTotalW - inner) / 2)

            let leftX = startX
            let centerLeftX = startX + sideW + inner
            let centerRightX = centerLeftX + mainEachW + inner
            let rightX = centerRightX + mainEachW + inner

            let mainFrame1 = CGRect(x: centerLeftX, y: startY, width: mainEachW, height: totalH)
            let mainFrame2 = CGRect(x: centerRightX, y: startY, width: mainEachW, height: totalH)

            let maxSideCount = max(1, Int((totalH + inner) / (minSideWindowHeight + inner)))
            let leftDisplayCount = min(leftCount, maxSideCount)
            let rightDisplayCount = min(rightCount, maxSideCount)

            let leftH = leftDisplayCount > 0 ? (totalH - inner * CGFloat(leftDisplayCount - 1)) / CGFloat(leftDisplayCount) : 0
            let rightH = rightDisplayCount > 0 ? (totalH - inner * CGFloat(rightDisplayCount - 1)) / CGFloat(rightDisplayCount) : 0

            var frames = [mainFrame1, mainFrame2]
            var currentLeftIdx = 0
            var currentRightIdx = 0

            for i in 1...totalSideCount {
                if i % 2 == 1 {
                    if currentLeftIdx < leftDisplayCount {
                        let sideY = startY + CGFloat(currentLeftIdx) * (leftH + inner)
                        frames.append(CGRect(x: leftX, y: sideY, width: sideW, height: leftH))
                        currentLeftIdx += 1
                    } else {
                        frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                    }
                } else {
                    if currentRightIdx < rightDisplayCount {
                        let sideY = startY + CGFloat(currentRightIdx) * (rightH + inner)
                        frames.append(CGRect(x: rightX, y: sideY, width: sideW, height: rightH))
                        currentRightIdx += 1
                    } else {
                        frames.append(CGRect(x: -4000, y: startY + CGFloat(i) * 10, width: 200, height: 200))
                    }
                }
            }
            return frames

        case .absoluteSplit2:
            if windowCount == 1 {
                return [CGRect(x: startX, y: startY, width: totalW, height: totalH)]
            }
            
            let mainW = (totalW - inner) / 2
            return [
                CGRect(x: startX, y: startY, width: mainW, height: totalH),
                CGRect(x: startX + mainW + inner, y: startY, width: mainW, height: totalH)
            ]

        case .absoluteSplit3:
            if windowCount == 1 {
                return [CGRect(x: startX, y: startY, width: totalW, height: totalH)]
            } else if windowCount == 2 {
                let mainW = (totalW - inner) / 2
                return [
                    CGRect(x: startX, y: startY, width: mainW, height: totalH),
                    CGRect(x: startX + mainW + inner, y: startY, width: mainW, height: totalH)
                ]
            }
            
            let mainW = (totalW - inner * 2) / 3
            let leftFrame = CGRect(x: startX, y: startY, width: mainW, height: totalH)
            let centerFrame = CGRect(x: startX + mainW + inner, y: startY, width: mainW, height: totalH)
            let rightFrame = CGRect(x: startX + (mainW + inner) * 2, y: startY, width: mainW, height: totalH)
            return [centerFrame, leftFrame, rightFrame]
        }
    }
}
