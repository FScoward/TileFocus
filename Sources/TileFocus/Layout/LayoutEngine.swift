import Foundation

// MARK: - Layout Protocol

/// タイリングレイアウトの基本プロトコル
protocol Layout {
    /// レイアウト名（UI 表示用）
    var name: String { get }

    /// 各ウィンドウのフレームを計算する
    /// - Parameters:
    ///   - windowCount: タイリング対象のウィンドウ数
    ///   - screenFrame: 画面の使用可能フレーム（Accessibility 座標系）
    /// - Returns: 各ウィンドウのフレーム（順番はウィンドウリストと対応）
    func calculateFrames(windowCount: Int, screenFrame: CGRect) -> [CGRect]
}

// MARK: - Layout Registry

/// 利用可能なレイアウトの一覧と自動選択ロジック
enum LayoutRegistry {

    /// 全レイアウトのリスト（ユーザーが切り替えられる順）
    static let allLayouts: [any Layout] = [
        CenterLayout(),
        HalfSplitLayout(),
        VerticalSplitLayout(),
        MasterStackLayout(),
        EqualGridLayout()
    ]

    /// ウィンドウ数に応じた推奨レイアウトを自動選択
    static func recommendedLayout(for windowCount: Int) -> any Layout {
        switch windowCount {
        case 0, 1:
            return CenterLayout()
        case 2:
            return HalfSplitLayout()
        case 3:
            return MasterStackLayout()
        default:
            return EqualGridLayout()
        }
    }
}
