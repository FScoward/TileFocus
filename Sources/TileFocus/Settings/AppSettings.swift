import Foundation

/// 格納方法の定義
enum StageMethod: String, CaseIterable, Identifiable {
    case offscreen
    case dock

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .offscreen: return "画面外に退避（高速・推奨）"
        case .dock: return "Dockにしまう（最小化）"
        }
    }
}

/// 王冠（マスターウィンドウ）の切り替え方法
enum CrownSwapTrigger: String, CaseIterable, Identifiable {
    case clickOnly
    case ctrlShiftClick

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .clickOnly: return "クリックのみ"
        case .ctrlShiftClick: return "Control + Shift + クリック"
        }
    }
}

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
        static let stageMethod = "stageMethod"
        static let mainWidthRatio = "mainWidthRatio"
        static let focusStylesByMonitor = "focusStylesByMonitor"
        static let crownSwapTrigger = "crownSwapTrigger"
        static let floatModeRatio = "floatModeRatio"
    }

    // MARK: - Settings

    /// 起動時のモード
    @Published var defaultMode: AppMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: Keys.defaultMode) }
    }

    /// Focus Modeでのメインウィンドウの幅比率
    @Published var mainWidthRatio: Double {
        didSet { defaults.set(mainWidthRatio, forKey: Keys.mainWidthRatio) }
    }

    /// Float Modeでの中央ウィンドウの表示比率
    @Published var floatModeRatio: Double {
        didSet { defaults.set(floatModeRatio, forKey: Keys.floatModeRatio) }
    }

    /// モニターごとの Focus Style 設定
    @Published var focusStylesByMonitor: [String: String] {
        didSet { defaults.set(focusStylesByMonitor, forKey: Keys.focusStylesByMonitor) }
    }

    /// 格納方法
    @Published var stageMethod: StageMethod {
        didSet { defaults.set(stageMethod.rawValue, forKey: Keys.stageMethod) }
    }

    /// 王冠の切り替え方法
    @Published var crownSwapTrigger: CrownSwapTrigger {
        didSet { defaults.set(crownSwapTrigger.rawValue, forKey: Keys.crownSwapTrigger) }
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
        let savedRatio = defaults.double(forKey: Keys.mainWidthRatio)
        mainWidthRatio = savedRatio == 0 ? 0.55 : savedRatio

        let savedFloatRatio = defaults.double(forKey: Keys.floatModeRatio)
        floatModeRatio = savedFloatRatio == 0 ? 0.55 : savedFloatRatio

        focusStylesByMonitor = defaults.dictionary(forKey: Keys.focusStylesByMonitor) as? [String: String] ?? [:]

        defaultMode = AppMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .off
        
        stageMethod = StageMethod(
            rawValue: defaults.string(forKey: Keys.stageMethod) ?? ""
        ) ?? .offscreen

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

        crownSwapTrigger = CrownSwapTrigger(
            rawValue: defaults.string(forKey: Keys.crownSwapTrigger) ?? ""
        ) ?? .clickOnly
    }

    /// TilingGap 構造体として返す
    var tilingGap: TilingGap {
        TilingGap(outer: tilingGapOuter, inner: tilingGapInner)
    }
}
