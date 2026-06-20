import Foundation

/// アプリ設定の永続化（UserDefaults ラッパー）
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Keys {
        static let defaultMode = "defaultMode"
        static let tilingGapOuter = "tilingGapOuter"
        static let tilingGapInner = "tilingGapInner"
        static let defaultLayoutIndex = "defaultLayoutIndex"
        static let launchAtLogin = "launchAtLogin"
    }

    // MARK: - Settings

    /// 起動時のモード
    @Published var defaultMode: AppMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode) }
    }

    /// タイリングの外側ギャップ（px）
    @Published var tilingGapOuter: CGFloat {
        didSet { defaults.set(Double(tilingGapOuter), forKey: Keys.tilingGapOuter) }
    }

    /// タイリングのウィンドウ間ギャップ（px）
    @Published var tilingGapInner: CGFloat {
        didSet { defaults.set(Double(tilingGapInner), forKey: Keys.tilingGapInner) }
    }

    /// デフォルトレイアウトのインデックス
    @Published var defaultLayoutIndex: Int {
        didSet { defaults.set(defaultLayoutIndex, forKey: Keys.defaultLayoutIndex) }
    }

    // MARK: - Init

    private init() {
        defaultMode = AppMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .off

        tilingGapOuter = CGFloat(
            defaults.double(forKey: Keys.tilingGapOuter) == 0
            ? 8.0
            : defaults.double(forKey: Keys.tilingGapOuter)
        )

        tilingGapInner = CGFloat(
            defaults.double(forKey: Keys.tilingGapInner) == 0
            ? 8.0
            : defaults.double(forKey: Keys.tilingGapInner)
        )

        defaultLayoutIndex = defaults.integer(forKey: Keys.defaultLayoutIndex)
    }

    /// TilingGap 構造体として返す
    var tilingGap: TilingGap {
        TilingGap(outer: tilingGapOuter, inner: tilingGapInner)
    }
}
