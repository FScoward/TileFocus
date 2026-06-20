import Foundation

// MARK: - Gap Config

/// タイリング時のウィンドウ間ギャップ設定
struct TilingGap {
    var outer: CGFloat  // 画面端のマージン
    var inner: CGFloat  // ウィンドウ間のギャップ

    static let `default` = TilingGap(outer: 8, inner: 8)
}

// MARK: - Center Layout

/// ウィンドウ 1 枚: 画面中央に 80% サイズで表示
///
/// ```
/// ┌─────────┐
/// │         │
/// │ Center  │
/// │         │
/// └─────────┘
/// ```
struct CenterLayout: Layout {
    var name: String { "Center" }
    var gap: TilingGap = .default

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        let width = screenFrame.width * 0.8
        let height = screenFrame.height * 0.8
        let x = screenFrame.minX + (screenFrame.width - width) / 2
        let y = screenFrame.minY + (screenFrame.height - height) / 2
        return Array(repeating: CGRect(x: x, y: y, width: width, height: height), count: windowCount)
    }
}

// MARK: - HalfSplit Layout

/// ウィンドウ 2 枚: 左右 50:50
///
/// ```
/// ┌────┬────┐
/// │    │    │
/// │ L  │ R  │
/// │    │    │
/// └────┴────┘
/// ```
struct HalfSplitLayout: Layout {
    var name: String { "HalfSplit" }
    var gap: TilingGap = .default

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        if windowCount == 1 { return CenterLayout().calculateFrames(windowCount: 1, screenFrame: screenFrame) }

        let innerGap = gap.inner / 2
        let outerGap = gap.outer
        let availWidth = screenFrame.width - outerGap * 2 - gap.inner
        let availHeight = screenFrame.height - outerGap * 2
        let halfWidth = availWidth / 2
        let x = screenFrame.minX + outerGap
        let y = screenFrame.minY + outerGap

        let left = CGRect(x: x, y: y, width: halfWidth, height: availHeight)
        let right = CGRect(x: x + halfWidth + gap.inner, y: y, width: halfWidth, height: availHeight)
        let frames = [left, right]
        return Array(frames.prefix(windowCount)) + Array(repeating: right, count: max(0, windowCount - 2))
    }
}

// MARK: - VerticalSplit Layout

/// ウィンドウ 2 枚: 上下 50:50
///
/// ```
/// ┌────────┐
/// │   T    │
/// ├────────┤
/// │   B    │
/// └────────┘
/// ```
struct VerticalSplitLayout: Layout {
    var name: String { "VerticalSplit" }
    var gap: TilingGap = .default

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        if windowCount == 1 { return CenterLayout().calculateFrames(windowCount: 1, screenFrame: screenFrame) }

        let outerGap = gap.outer
        let availWidth = screenFrame.width - outerGap * 2
        let availHeight = screenFrame.height - outerGap * 2 - gap.inner
        let halfHeight = availHeight / 2
        let x = screenFrame.minX + outerGap
        let y = screenFrame.minY + outerGap

        let top = CGRect(x: x, y: y, width: availWidth, height: halfHeight)
        let bottom = CGRect(x: x, y: y + halfHeight + gap.inner, width: availWidth, height: halfHeight)
        let frames = [top, bottom]
        return Array(frames.prefix(windowCount)) + Array(repeating: bottom, count: max(0, windowCount - 2))
    }
}

// MARK: - MasterStack Layout

/// ウィンドウ 2-4 枚: 左 60% にマスター、右 40% にスタック（縦分割）
///
/// ```
/// ┌──────┬───┐
/// │      │ S1│
/// │  M   ├───┤
/// │      │ S2│
/// └──────┴───┘
/// ```
struct MasterStackLayout: Layout {
    var name: String { "MasterStack" }
    var gap: TilingGap = .default
    /// マスターウィンドウの幅比率
    var masterRatio: CGFloat = 0.6

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        if windowCount == 1 { return CenterLayout().calculateFrames(windowCount: 1, screenFrame: screenFrame) }

        let outerGap = gap.outer
        let availWidth = screenFrame.width - outerGap * 2 - gap.inner
        let availHeight = screenFrame.height - outerGap * 2
        let masterWidth = availWidth * masterRatio
        let stackWidth = availWidth * (1 - masterRatio)
        let x = screenFrame.minX + outerGap
        let y = screenFrame.minY + outerGap

        let master = CGRect(x: x, y: y, width: masterWidth, height: availHeight)
        let stackX = x + masterWidth + gap.inner
        let stackCount = windowCount - 1
        let stackItemHeight = (availHeight - gap.inner * CGFloat(stackCount - 1)) / CGFloat(max(stackCount, 1))

        var frames = [master]
        for i in 0..<stackCount {
            let stackY = y + CGFloat(i) * (stackItemHeight + gap.inner)
            frames.append(CGRect(x: stackX, y: stackY, width: stackWidth, height: stackItemHeight))
        }
        return frames
    }
}

// MARK: - EqualGrid Layout

/// ウィンドウ 3-4 枚: 均等グリッド分割
///
/// ```
/// ┌────┬────┐
/// │ 1  │ 2  │
/// ├────┼────┤
/// │ 3  │ 4  │
/// └────┴────┘
/// ```
struct EqualGridLayout: Layout {
    var name: String { "EqualGrid" }
    var gap: TilingGap = .default

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        if windowCount == 1 { return CenterLayout().calculateFrames(windowCount: 1, screenFrame: screenFrame) }
        if windowCount == 2 { return HalfSplitLayout().calculateFrames(windowCount: 2, screenFrame: screenFrame) }

        let outerGap = gap.outer
        // グリッドの列数と行数を計算
        let cols = Int(ceil(sqrt(Double(windowCount))))
        let rows = Int(ceil(Double(windowCount) / Double(cols)))

        let totalHGap = gap.inner * CGFloat(cols - 1)
        let totalVGap = gap.inner * CGFloat(rows - 1)
        let availWidth = screenFrame.width - outerGap * 2 - totalHGap
        let availHeight = screenFrame.height - outerGap * 2 - totalVGap
        let cellWidth = availWidth / CGFloat(cols)
        let cellHeight = availHeight / CGFloat(rows)

        var frames: [CGRect] = []
        for i in 0..<windowCount {
            let col = i % cols
            let row = i / cols
            let x = screenFrame.minX + outerGap + CGFloat(col) * (cellWidth + gap.inner)
            let y = screenFrame.minY + outerGap + CGFloat(row) * (cellHeight + gap.inner)
            frames.append(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
        }
        return frames
    }
}
