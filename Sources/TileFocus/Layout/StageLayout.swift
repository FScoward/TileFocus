import Foundation

/// Stage Mode 用のレイアウト計算
/// 画面左側のサイドバー領域を避けた上で、メインウィンドウを程よいサイズで中央に配置する
struct StageLayout: Layout {
    var name: String { "Stage" }

    /// 左側のサイドバー幅
    let sidebarWidth: CGFloat = 180
    /// 外側の余白
    let outerGap: CGFloat = 20

    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect] {
        guard windowCount > 0 else { return [] }

        // メインウィンドウが配置可能な利用可能領域（左側のサイドバーを避ける）
        let availableX = screenFrame.minX + sidebarWidth + outerGap
        let availableY = screenFrame.minY + outerGap
        let availableW = screenFrame.width - sidebarWidth - outerGap * 2
        let availableH = screenFrame.height - outerGap * 2

        // 利用可能領域に対して、例えば横幅 80%、縦幅 85% のサイズで中央配置する
        let targetW = availableW * 0.8
        let targetH = availableH * 0.85
        
        let targetX = availableX + (availableW - targetW) / 2
        let targetY = availableY + (availableH - targetH) / 2

        let mainFrame = CGRect(x: targetX, y: targetY, width: targetW, height: targetH)
        
        var frames = [mainFrame]
        if windowCount > 1 {
            for _ in 1..<windowCount {
                frames.append(CGRect(x: -4000, y: screenFrame.minY, width: 200, height: 200))
            }
        }
        return frames
    }
}
