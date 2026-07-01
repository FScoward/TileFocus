import SwiftUI
import AppKit

/// 設定画面 UI
struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem {
                    Label("一般", systemImage: "gearshape")
                }
                .tag(0)

            TilingSettingsTab()
                .tabItem {
                    Label("パディング", systemImage: "square.grid.2x2")
                }
                .tag(1)

            HotKeySettingsTab()
                .tabItem {
                    Label("ホットキー", systemImage: "keyboard")
                }
                .tag(2)
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General Settings

private struct GeneralSettingsTab: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("起動") {
                Picker("起動時のモード", selection: $settings.defaultMode) {
                    ForEach(AppMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("ウィンドウ格納 (Focus Mode)") {
                Picker("格納方法", selection: $settings.stageMethod) {
                    ForEach(StageMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            }

            Section("王冠（マスターウィンドウ）の切り替え") {
                Picker("切り替え方法", selection: $settings.crownSwapTrigger) {
                    ForEach(CrownSwapTrigger.allCases) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
            }

            Section("フォーカス（遮光機能）") {
                Toggle("選択したウィンドウ以外を暗くする (Dim)", isOn: $settings.isDimmingEnabled)
                if settings.isDimmingEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("暗さ（不透明度）")
                            Spacer()
                            Text("\(Int(settings.dimmingOpacity * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.dimmingOpacity, in: 0.1...0.8, step: 0.05)
                    }
                }
            }

            Section("自動配置の対象外") {
                Button {
                    excludeFrontmostApplication()
                } label: {
                    Label("現在のアプリを対象外にする", systemImage: "rectangle.badge.minus")
                }

                if settings.excludedAppIdentifiers.isEmpty {
                    Text("対象外アプリはありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.excludedAppIdentifiers, id: \.self) { identifier in
                        HStack {
                            Text(settings.excludedAppNamesByIdentifier[identifier] ?? displayName(for: identifier))
                            Spacer()
                            Button {
                                settings.includeInAutoPlacement(identifier: identifier)
                                refreshLayoutAfterExclusionChange()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("自動配置の対象に戻す")
                        }
                    }
                }
            }

            Section("レイアウト (Focus Mode)") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("メインウィンドウの幅比率")
                        Spacer()
                        Text("\(Int(settings.mainWidthRatio * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.mainWidthRatio, in: 0.3...0.8, step: 0.05)
                }
            }

            Section("レイアウト (Tiling Mode)") {
                Picker("デフォルトレイアウト", selection: $settings.defaultLayoutIndex) {
                    ForEach(LayoutRegistry.allLayouts.indices, id: \.self) { index in
                        Text(LayoutRegistry.allLayouts[index].name).tag(index)
                    }
                }
            }

            Section("レイアウト (Float Mode)") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("中央ウィンドウの幅比率")
                        Spacer()
                        Text("\(Int(settings.floatModeWidthRatio * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.floatModeWidthRatio, in: 0.3...0.8, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("中央ウィンドウの高さ比率")
                        Spacer()
                        Text("\(Int(settings.floatModeHeightRatio * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.floatModeHeightRatio, in: 0.3...0.8, step: 0.05)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings.mainWidthRatio) { _ in
            WindowManager.shared.requestFocusLayoutUpdate()
        }
        .onChange(of: settings.floatModeWidthRatio) { _ in
            WindowManager.shared.requestFocusLayoutUpdate()
        }
        .onChange(of: settings.floatModeHeightRatio) { _ in
            WindowManager.shared.requestFocusLayoutUpdate()
        }
        .onChange(of: settings.isDimmingEnabled) { _ in
            DimmingManager.shared.updateDimmingState()
        }
        .onChange(of: settings.dimmingOpacity) { _ in
            DimmingManager.shared.updateFocusedWindowRect()
        }
    }

    private func excludeFrontmostApplication() {
        if let focused = WindowManager.shared.getFocusedWindow() {
            settings.excludeFromAutoPlacement(bundleIdentifier: focused.bundleIdentifier, appName: focused.appName)
            refreshLayoutAfterExclusionChange()
            return
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let appName = app.localizedName else {
            return
        }
        settings.excludeFromAutoPlacement(bundleIdentifier: app.bundleIdentifier, appName: appName)
        refreshLayoutAfterExclusionChange()
    }

    private func refreshLayoutAfterExclusionChange() {
        WindowManager.shared.refreshWindowList()
        WindowManager.shared.requestRetile()
        WindowManager.shared.requestFocusLayoutUpdate()
    }

    private func displayName(for identifier: String) -> String {
        if identifier.hasPrefix("bundle:") {
            return String(identifier.dropFirst("bundle:".count))
        }
        if identifier.hasPrefix("name:") {
            return String(identifier.dropFirst("name:".count))
        }
        return identifier
    }
}

// MARK: - Tiling Settings

private struct TilingSettingsTab: View {
    @StateObject private var settings = AppSettings.shared

    private func triggerLayoutUpdate() {
        WindowManager.shared.requestRetile()
        WindowManager.shared.requestFocusLayoutUpdate()
    }

    var body: some View {
        Form {
            Section("パディング（余白）") {
                HStack {
                    Text("画面端とのパディング (外側)")
                    Spacer()
                    Slider(value: $settings.tilingGapOuter, in: 0...40, step: 2)
                        .frame(width: 150)
                        .onChange(of: settings.tilingGapOuter) { _ in
                            triggerLayoutUpdate()
                        }
                    Text("\(Int(settings.tilingGapOuter)) px")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }

                HStack {
                    Text("ウィンドウ間のパディング (内側)")
                    Spacer()
                    Slider(value: $settings.tilingGapInner, in: 0...40, step: 2)
                        .frame(width: 150)
                        .onChange(of: settings.tilingGapInner) { _ in
                            triggerLayoutUpdate()
                        }
                    Text("\(Int(settings.tilingGapInner)) px")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - HotKey Settings

private struct HotKeySettingsTab: View {
    private let hotKeys: [(String, String)] = [
        ("Focus Mode ON/OFF", "⌃⌘F"),
        ("Float Mode ON/OFF", "⌃⌘L"),
        ("フォーカス中のウィンドウを格納", "⌃⌘S"),
        ("格納ウィンドウを全復帰", "⌃⌘R"),
        ("次のレイアウト", "⌃⌘→"),
        ("前のレイアウト", "⌃⌘←")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ホットキー（Phase 5 でカスタマイズ対応予定）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()

            List(hotKeys, id: \.0) { item in
                HStack {
                    Text(item.0)
                    Spacer()
                    Text(item.1)
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

#if canImport(PreviewsMacros)
#Preview {
    SettingsView()
}
#endif
