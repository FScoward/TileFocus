import SwiftUI

/// メニューバーのドロップダウン UI
struct MenuBarView: View {
    @EnvironmentObject private var windowManager: WindowManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー
            headerSection

            Divider()

            // モード切り替え
            modeSection

            Divider()

            // レイアウト選択（Tiling Mode 時のみ）
            if windowManager.currentMode == .tiling {
                layoutSection
                Divider()
            }

            // 格納ウィンドウ一覧（Phase 3 で充実予定）
            if !windowManager.stagedWindows.isEmpty {
                stagedWindowsSection
                Divider()
            }

            // アクション
            actionSection

            Divider()

            // アプリ操作
            appSection
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Image(systemName: "rectangle.3.group")
                .foregroundStyle(.blue)
            Text("TileFocus")
                .fontWeight(.semibold)
            Spacer()
            // 現在のモード表示
            Text(windowManager.currentMode.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(windowManager.currentMode.accentColor.opacity(0.15))
                .foregroundStyle(windowManager.currentMode.accentColor)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Mode Section

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("モード")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            ForEach(AppMode.allCases) { mode in
                Button {
                    windowManager.switchMode(to: mode)
                } label: {
                    HStack {
                        Image(systemName: mode.iconName)
                            .frame(width: 16)
                        Text(mode.displayName)
                        Spacer()
                        if windowManager.currentMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .font(.caption)
                        }
                        Text(mode.shortcutLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    windowManager.currentMode == mode
                        ? Color.accentColor.opacity(0.08)
                        : Color.clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Layout Section

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("レイアウト")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            HStack(spacing: 4) {
                Button {
                    windowManager.previousLayout()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])

                Text(windowManager.currentLayout?.name ?? "自動")
                    .frame(maxWidth: .infinity)
                    .font(.callout)

                Button {
                    windowManager.nextLayout()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Staged Windows Section

    private var stagedWindowsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("格納中 (\(windowManager.stagedWindows.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            ForEach(windowManager.stagedWindows) { window in
                Button {
                    windowManager.unstageWindow(window)
                } label: {
                    HStack {
                        Image(systemName: "app.badge")
                            .frame(width: 16)
                        Text(window.title.isEmpty ? window.appName : window.title)
                            .lineLimit(1)
                        Spacer()
                        Text("復帰")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 2) {

            // Tiling Mode 時のみ: マスターウィンドウ操作
            if windowManager.currentMode == .tiling {
                // 現在のマスター表示
                if let master = windowManager.masterWindow {
                    HStack {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.yellow)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("マスター")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(master.title.isEmpty ? master.appName : master.title)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }

                // マスター昇格ボタン
                Button {
                    windowManager.promoteCurrentWindowToMaster()
                } label: {
                    HStack {
                        Image(systemName: "crown")
                            .frame(width: 16)
                        Text("フロントウィンドウをマスターに")
                        Spacer()
                        Text("⌃⌘M")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)

                Divider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            // Focus Mode 時: ウィンドウ一覧による入れ替え
            if windowManager.currentMode == .focus {
                Text("フォーカス切り替え")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                ForEach(windowManager.managedWindows.filter { $0.state != .staged }) { window in
                    Button {
                        Log.info("MenuBarView", "ウィンドウクリック: \(window.appName) - \(window.title) id=\(window.id)")
                        windowManager.switchFocusedWindow(to: window.id)
                    } label: {
                        HStack {
                            Image(systemName: windowManager.focusedWindowID == window.id
                                  ? "eye.fill" : "eye")
                                .foregroundStyle(windowManager.focusedWindowID == window.id
                                                 ? Color.accentColor : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(window.appName)
                                    .font(.caption)
                                    .fontWeight(windowManager.focusedWindowID == window.id ? .semibold : .regular)
                                if !window.title.isEmpty && window.title != window.appName {
                                    Text(window.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if windowManager.focusedWindowID == window.id {
                                Text("フォーカス中")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        windowManager.focusedWindowID == window.id
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 4)
                }

                Divider()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }

            Button {
                windowManager.stageFocusedWindow()
            } label: {
                HStack {
                    Image(systemName: "arrow.left.to.line")
                        .frame(width: 16)
                    Text("フォーカスウィンドウを格納")
                    Spacer()
                    Text("⌃⌘S")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .disabled(windowManager.currentMode == .off)

            Button {
                windowManager.unstageAllWindows()
            } label: {
                HStack {
                    Image(systemName: "arrow.uturn.right")
                        .frame(width: 16)
                    Text("格納ウィンドウを全復帰")
                    Spacer()
                    Text("⌃⌘R")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .disabled(windowManager.stagedWindows.isEmpty)
        }
    }

    // MARK: - App Section

    private var appSection: some View {
        VStack(spacing: 2) {
            if #available(macOS 14.0, *) {
                SettingsLink {
                    HStack {
                        Image(systemName: "gearshape")
                            .frame(width: 16)
                        Text("設定...")
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                            .frame(width: 16)
                        Text("設定...")
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
            }

            // ログファイルを Finder で開く
            Button {
                let logPath = Log.logFilePath
                NSWorkspace.shared.selectFile(logPath, inFileViewerRootedAtPath: "")
            } label: {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                        .frame(width: 16)
                    Text("ログを開く")
                    Spacer()
                    Text("~/Library/Logs/TileFocus/")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)

            Button("TileFocus を終了") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
        }
    }
}
