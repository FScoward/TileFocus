import Foundation

/// お道具箱へしまう方法の定義
enum StageMethod: String, CaseIterable, Identifiable {
    case offscreen
    case dock

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .offscreen: return "画面外のお道具箱（非推奨）"
        case .dock: return "Dock経由でお道具箱にしまう"
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
        static let modesBySpace = "modesBySpace"
        static let crownSwapTrigger = "crownSwapTrigger"
        static let isAltTabCrownSelectionEnabled = "isAltTabCrownSelectionEnabled"
        static let floatModeWidthRatio = "floatModeWidthRatio"
        static let floatModeHeightRatio = "floatModeHeightRatio"
        static let isDimmingEnabled = "isDimmingEnabled"
        static let dimmingOpacity = "dimmingOpacity"
        static let alwaysShowStageTopBar = "alwaysShowStageTopBar"
        static let excludedAppIdentifiers = "excludedAppIdentifiers"
        static let excludedAppNamesByIdentifier = "excludedAppNamesByIdentifier"
        static let isArrangementMemoryEnabled = "isArrangementMemoryEnabled"
        static let rememberedWindowArrangements = "rememberedWindowArrangements"
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

    /// Float Modeでの中央ウィンドウの横比率
    @Published var floatModeWidthRatio: Double {
        didSet { defaults.set(floatModeWidthRatio, forKey: Keys.floatModeWidthRatio) }
    }

    /// Float Modeでの中央ウィンドウの縦比率
    @Published var floatModeHeightRatio: Double {
        didSet { defaults.set(floatModeHeightRatio, forKey: Keys.floatModeHeightRatio) }
    }

    /// モニターごとの Focus Style 設定
    @Published var focusStylesByMonitor: [String: String] {
        didSet { defaults.set(focusStylesByMonitor, forKey: Keys.focusStylesByMonitor) }
    }

    /// 仮想スペースごとのモード設定
    @Published var modesBySpace: [String: String] {
        didSet { defaults.set(modesBySpace, forKey: Keys.modesBySpace) }
    }

    /// お道具箱へしまう方法
    @Published var stageMethod: StageMethod {
        didSet { defaults.set(stageMethod.rawValue, forKey: Keys.stageMethod) }
    }

    /// 王冠の切り替え方法
    @Published var crownSwapTrigger: CrownSwapTrigger {
        didSet { defaults.set(crownSwapTrigger.rawValue, forKey: Keys.crownSwapTrigger) }
    }

    /// Alt+Tab で王冠の移動先候補を選択するかどうか
    @Published var isAltTabCrownSelectionEnabled: Bool {
        didSet { defaults.set(isAltTabCrownSelectionEnabled, forKey: Keys.isAltTabCrownSelectionEnabled) }
    }

    /// 選択したウィンドウ以外を暗くするかどうか (Dimming)
    @Published var isDimmingEnabled: Bool {
        didSet { defaults.set(isDimmingEnabled, forKey: Keys.isDimmingEnabled) }
    }

    /// 選択したウィンドウ以外を暗くする際の不透明度
    @Published var dimmingOpacity: Double {
        didSet { defaults.set(dimmingOpacity, forKey: Keys.dimmingOpacity) }
    }

    /// 上部ホバーを常に表示するかどうか
    @Published var alwaysShowStageTopBar: Bool {
        didSet { defaults.set(alwaysShowStageTopBar, forKey: Keys.alwaysShowStageTopBar) }
    }

    /// 自動配置の対象外にするアプリ識別子
    @Published var excludedAppIdentifiers: [String] {
        didSet { defaults.set(excludedAppIdentifiers, forKey: Keys.excludedAppIdentifiers) }
    }

    /// 対象外アプリの表示名
    @Published var excludedAppNamesByIdentifier: [String: String] {
        didSet { defaults.set(excludedAppNamesByIdentifier, forKey: Keys.excludedAppNamesByIdentifier) }
    }

    /// 表示中のウィンドウ構成に応じて、記憶済み配置を再現する試験機能
    @Published var isArrangementMemoryEnabled: Bool {
        didSet { defaults.set(isArrangementMemoryEnabled, forKey: Keys.isArrangementMemoryEnabled) }
    }

    /// ウィンドウ構成ごとに記憶した配置
    @Published private(set) var rememberedWindowArrangements: [WindowArrangementSnapshot] {
        didSet { saveRememberedWindowArrangements() }
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

        let savedFloatWidthRatio = defaults.double(forKey: Keys.floatModeWidthRatio)
        floatModeWidthRatio = savedFloatWidthRatio == 0 ? 0.55 : savedFloatWidthRatio

        let savedFloatHeightRatio = defaults.double(forKey: Keys.floatModeHeightRatio)
        floatModeHeightRatio = savedFloatHeightRatio == 0 ? 0.55 : savedFloatHeightRatio

        focusStylesByMonitor = defaults.dictionary(forKey: Keys.focusStylesByMonitor) as? [String: String] ?? [:]
        modesBySpace = defaults.dictionary(forKey: Keys.modesBySpace) as? [String: String] ?? [:]

        defaultMode = AppMode(
            rawValue: defaults.string(forKey: Keys.defaultMode) ?? ""
        ) ?? .off
        
        stageMethod = StageMethod(
            rawValue: defaults.string(forKey: Keys.stageMethod) ?? ""
        ) ?? .dock

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
        isAltTabCrownSelectionEnabled = defaults.object(forKey: Keys.isAltTabCrownSelectionEnabled) as? Bool ?? true

        isDimmingEnabled = defaults.object(forKey: Keys.isDimmingEnabled) as? Bool ?? false

        let savedDimmingOpacity = defaults.double(forKey: Keys.dimmingOpacity)
        dimmingOpacity = savedDimmingOpacity == 0 ? 0.3 : savedDimmingOpacity
        alwaysShowStageTopBar = defaults.object(forKey: Keys.alwaysShowStageTopBar) as? Bool ?? false

        excludedAppIdentifiers = defaults.stringArray(forKey: Keys.excludedAppIdentifiers) ?? []
        excludedAppNamesByIdentifier = defaults.dictionary(forKey: Keys.excludedAppNamesByIdentifier) as? [String: String] ?? [:]
        isArrangementMemoryEnabled = defaults.object(forKey: Keys.isArrangementMemoryEnabled) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.rememberedWindowArrangements),
           let decoded = try? JSONDecoder().decode([WindowArrangementSnapshot].self, from: data) {
            rememberedWindowArrangements = decoded
        } else {
            rememberedWindowArrangements = []
        }
    }

    /// TilingGap 構造体として返す
    var tilingGap: TilingGap {
        TilingGap(outer: tilingGapOuter, inner: tilingGapInner)
    }

    func appExclusionIdentifier(bundleIdentifier: String?, appName: String) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return "bundle:\(bundleIdentifier)"
        }
        return "name:\(appName)"
    }

    func isAutoPlacementExcluded(bundleIdentifier: String?, appName: String) -> Bool {
        excludedAppIdentifiers.contains(appExclusionIdentifier(bundleIdentifier: bundleIdentifier, appName: appName))
    }

    func excludeFromAutoPlacement(bundleIdentifier: String?, appName: String) {
        let identifier = appExclusionIdentifier(bundleIdentifier: bundleIdentifier, appName: appName)
        if !excludedAppIdentifiers.contains(identifier) {
            excludedAppIdentifiers.append(identifier)
        }
        excludedAppNamesByIdentifier[identifier] = appName
    }

    func includeInAutoPlacement(identifier: String) {
        excludedAppIdentifiers.removeAll { $0 == identifier }
        excludedAppNamesByIdentifier.removeValue(forKey: identifier)
    }

    func mode(forSpaceKey key: String) -> AppMode? {
        guard let raw = modesBySpace[key] else { return nil }
        return AppMode(rawValue: raw)
    }

    func setMode(_ mode: AppMode, forSpaceKey key: String) {
        guard !key.isEmpty else { return }
        modesBySpace[key] = mode.rawValue
    }

    func rememberWindowArrangement(_ snapshot: WindowArrangementSnapshot) {
        rememberedWindowArrangements.removeAll { $0.layoutKey == snapshot.layoutKey }
        rememberedWindowArrangements.insert(snapshot, at: 0)
    }

    func removeRememberedWindowArrangement(id: UUID) {
        rememberedWindowArrangements.removeAll { $0.id == id }
    }

    func rememberedArrangement(for windows: [ManagedWindow], mode: AppMode) -> WindowArrangementSnapshot? {
        let layoutKey = WindowArrangementSnapshot.layoutKey(for: windows, mode: mode)
        return rememberedWindowArrangements.first { $0.layoutKey == layoutKey }
    }

    private func saveRememberedWindowArrangements() {
        guard let data = try? JSONEncoder().encode(rememberedWindowArrangements) else { return }
        defaults.set(data, forKey: Keys.rememberedWindowArrangements)
    }
}
