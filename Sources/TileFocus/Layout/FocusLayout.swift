import Foundation

/// Focus Mode のレイアウト計算
///
/// ```
/// ┌──┐                ┌──┐
/// │S1│                │S2│
/// └──┘                └──┘
///      ┌────────────┐
///      │            │
///      │   MAIN     │
///      │            │
///      └────────────┘
/// ┌──┐                ┌──┐
/// │S3│                │S4│
/// └──┘                └──┘
/// ```
struct FocusLayout: Layout {
    var name: String { "Focus" }

    /// メインウィンドウのサイズ比率
    var mainRatio: CGFloat = 0.75
    /// サブウィンドウのサイズ比率
    var subRatio: CGFloat = 0.20

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }
        if windowCount == 1 {
            return [mainFrame(in: screenFrame)]
        }

        var frames = [mainFrame(in: screenFrame)]
        let subCount = windowCount - 1
        let subFrames = subWindowFrames(count: subCount, in: screenFrame)
        frames += subFrames
        return frames
    }

    // MARK: - Private

    /// メインウィンドウのフレーム（画面中央に mainRatio サイズ）
    private func mainFrame(in screenFrame: CGRect) -> CGRect {
        let width = screenFrame.width * mainRatio
        let height = screenFrame.height * mainRatio
        let x = screenFrame.minX + (screenFrame.width - width) / 2
        let y = screenFrame.minY + (screenFrame.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// サブウィンドウのフレーム一覧
    /// - 4枚以下: 四隅に配置
    /// - 5枚以上: 辺に沿って均等配置
    private func subWindowFrames(count: Int, in screenFrame: CGRect) -> [CGRect] {
        let subW = screenFrame.width * subRatio
        let subH = screenFrame.height * subRatio
        let margin: CGFloat = 16

        if count <= 4 {
            // 四隅の位置
            let corners: [CGRect] = [
                // 左上
                CGRect(x: screenFrame.minX + margin,
                       y: screenFrame.minY + margin,
                       width: subW, height: subH),
                // 右上
                CGRect(x: screenFrame.maxX - subW - margin,
                       y: screenFrame.minY + margin,
                       width: subW, height: subH),
                // 左下
                CGRect(x: screenFrame.minX + margin,
                       y: screenFrame.maxY - subH - margin,
                       width: subW, height: subH),
                // 右下
                CGRect(x: screenFrame.maxX - subW - margin,
                       y: screenFrame.maxY - subH - margin,
                       width: subW, height: subH)
            ]
            return Array(corners.prefix(count))
        } else {
            // 5枚以上: 上辺・下辺・左辺・右辺に均等配置
            return distributeAlongEdges(count: count, in: screenFrame, subW: subW, subH: subH, margin: margin)
        }
    }

    private func distributeAlongEdges(
        count: Int,
        in screenFrame: CGRect,
        subW: CGFloat,
        subH: CGFloat,
        margin: CGFloat
    ) -> [CGRect] {
        var frames: [CGRect] = []

        // 上辺と下辺に交互に配置
        let topCount = (count + 1) / 2
        let bottomCount = count / 2

        let topSpacing = screenFrame.width / CGFloat(topCount + 1)
        for i in 0..<topCount {
            let x = screenFrame.minX + topSpacing * CGFloat(i + 1) - subW / 2
            let y = screenFrame.minY + margin
            frames.append(CGRect(x: x, y: y, width: subW, height: subH))
        }

        let bottomSpacing = screenFrame.width / CGFloat(bottomCount + 1)
        for i in 0..<bottomCount {
            let x = screenFrame.minX + bottomSpacing * CGFloat(i + 1) - subW / 2
            let y = screenFrame.maxY - subH - margin
            frames.append(CGRect(x: x, y: y, width: subW, height: subH))
        }

        return frames
    }
}
