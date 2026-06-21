import SwiftUI

// MARK: - WindowState

/// ウィンドウの現在の状態
enum WindowState: String, Codable {
    /// タイリング対象（アクティブに管理中）
    case tiled
    /// サイドバーに格納済み
    case staged
    /// Focus Mode でメインウィンドウ
    case focused
    /// Focus Mode でサブウィンドウ（縮小表示）
    case focusSub
}

// MARK: - AppMode

/// アプリ全体のモード
enum AppMode: String, CaseIterable, Identifiable {
    case off
    case tiling
    case focus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "オフ"
        case .tiling: return "Tiling Mode"
        case .focus: return "Focus Mode"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "rectangle.slash"
        case .tiling: return "rectangle.3.group"
        case .focus: return "rectangle.center.inset.filled"
        }
    }

    var accentColor: Color {
        switch self {
        case .off: return .secondary
        case .tiling: return .blue
        case .focus: return .purple
        }
    }

    var shortcutLabel: String {
        switch self {
        case .off: return ""
        case .tiling: return "⌃⌘T"
        case .focus: return "⌃⌘F"
        }
    }
}

// MARK: - FocusStyle

/// Focus Mode におけるメインウィンドウとサブウィンドウの配置スタイル
enum FocusStyle: String, CaseIterable, Identifiable {
    case centered
    case leftMain
    case rightMain
    case splitCentered
    case absoluteSplit2
    case absoluteSplit3

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .centered: return "中央メイン"
        case .leftMain: return "左メイン"
        case .rightMain: return "右メイン"
        case .splitCentered: return "中央2分割"
        case .absoluteSplit2: return "完全2分割"
        case .absoluteSplit3: return "完全3分割"
        }
    }

    var iconName: String {
        switch self {
        case .centered: return "rectangle.center.inset.filled"
        case .leftMain: return "square.leadingthird.inset.filled"
        case .rightMain: return "square.trailingthird.inset.filled"
        case .splitCentered: return "rectangle.split.3x1.fill"
        case .absoluteSplit2: return "square.split.2x1.fill"
        case .absoluteSplit3: return "square.split.3x1.fill"
        }
    }
}
