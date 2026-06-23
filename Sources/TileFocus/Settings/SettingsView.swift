import SwiftUI

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



            HotKeySettingsTab()
                .tabItem {
                    Label("ホットキー", systemImage: "keyboard")
                }
                .tag(2)
        }
        .frame(width: 480, height: 360)
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
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings.mainWidthRatio) { _ in
            WindowManager.shared.requestFocusLayoutUpdate()
        }
    }
}

// MARK: - Tiling Settings

private struct TilingSettingsTab: View {
    @StateObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("レイアウト") {
                Picker("デフォルトレイアウト", selection: $settings.defaultLayoutIndex) {
                    ForEach(LayoutRegistry.allLayouts.indices, id: \.self) { index in
                        Text(LayoutRegistry.allLayouts[index].name).tag(index)
                    }
                }
            }

            Section("ギャップ") {
                HStack {
                    Text("外側のマージン")
                    Spacer()
                    Slider(value: $settings.tilingGapOuter, in: 0...40, step: 2)
                        .frame(width: 150)
                    Text("\(Int(settings.tilingGapOuter)) px")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }

                HStack {
                    Text("ウィンドウ間のギャップ")
                    Spacer()
                    Slider(value: $settings.tilingGapInner, in: 0...40, step: 2)
                        .frame(width: 150)
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

#Preview {
    SettingsView()
}
