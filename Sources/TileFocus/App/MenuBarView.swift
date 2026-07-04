import SwiftUI

/// メニューバーのドロップダウン UI
struct MenuBarView: View {
    @EnvironmentObject private var windowManager: WindowManager
    @StateObject private var settings = AppSettings.shared
    @State private var arrangementName = ""
    @State private var hoveredArrangementID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ヘッダー
            headerSection

            Divider()

            // 権限警告
            if !PermissionChecker.isAccessibilityEnabled {
                permissionWarningSection
                Divider()
            }

            // モード切り替え
            modeSection

            Divider()
            
            // レイアウト選択（Tiling Mode 時のみ）
            if windowManager.currentMode == .tiling {
                layoutSection
                Divider()
            }

            // お道具箱にしまったウィンドウ一覧
            if !windowManager.stagedWindows.isEmpty {
                stagedWindowsSection
                Divider()
            }

            // アクション
            actionSection

            Divider()

            // 配置記憶
            arrangementMemorySection

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

    private var permissionWarningSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("アクセシビリティ権限がありません")
                    .font(.footnote)
                    .fontWeight(.bold)
            }
            Text("ウィンドウ配置機能を利用するには、システム設定での許可が必要です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            Button {
                PermissionChecker.openAccessibilitySettings()
            } label: {
                Text("システム設定を開く")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
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
            Label("お道具箱 (\(windowManager.stagedWindows.count))", systemImage: "archivebox.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            ForEach(windowManager.stagedWindows) { window in
                Button {
                    windowManager.unstageWindow(window)
                } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .frame(width: 16)
                        Text(window.title.isEmpty ? window.appName : window.title)
                            .lineLimit(1)
                        Spacer()
                        Text("取り出す")
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
                    Image(systemName: "archivebox.fill")
                        .frame(width: 16)
                    Text("フォーカスウィンドウをしまう")
                    Spacer()
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
                    Image(systemName: "tray.and.arrow.up.fill")
                        .frame(width: 16)
                    Text("お道具箱から全て取り出す")
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

    // MARK: - Arrangement Memory Section

    private var arrangementMemorySection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("配置記憶")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 4)

            HStack(spacing: 8) {
                Image(systemName: "rectangle.3.group.bubble")
                    .frame(width: 16)

                TextField("名前", text: $arrangementName)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button {
                    if windowManager.rememberCurrentArrangement(named: arrangementName) {
                        arrangementName = ""
                    }
                } label: {
                    Label("記憶", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!canRememberNamedArrangement)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .padding(.horizontal, 4)

            if settings.rememberedWindowArrangements.isEmpty {
                HStack {
                    Image(systemName: "tray")
                        .frame(width: 16)
                    Text("記憶済み配置はありません")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
            } else {
                ForEach(settings.rememberedWindowArrangements) { snapshot in
                    rememberedArrangementRow(snapshot)
                }
            }
        }
    }

    private var canRememberNamedArrangement: Bool {
        !windowManager.managedWindows.filter { $0.state != .staged }.isEmpty
    }

    private func rememberedArrangementRow(_ snapshot: WindowArrangementSnapshot) -> some View {
        let canApply = snapshot.matchesWindowCombination(
            windows: windowManager.managedWindows.filter { $0.state != .staged }
        )
        let isHovered = hoveredArrangementID == snapshot.id

        return HStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(isHovered ? .blue : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.name)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(snapshot.placements.count)枚 / \(snapshot.capturedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    windowManager.applyRememberedArrangement(snapshot)
                } label: {
                    Image(systemName: "arrow.down.to.line.compact")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(!canApply)
                .help(canApply ? "この配置を適用" : "現在のウィンドウ構成では適用できません")

                Button {
                    settings.removeRememberedWindowArrangement(id: snapshot.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("記憶済み配置を削除")
            }
            .opacity(isHovered ? 1 : 0)
            .frame(width: 44)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canApply {
                windowManager.applyRememberedArrangement(snapshot)
            }
        }
        .onHover { hovering in
            hoveredArrangementID = hovering ? snapshot.id : nil
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
