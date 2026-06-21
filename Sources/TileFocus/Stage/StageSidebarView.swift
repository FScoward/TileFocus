import SwiftUI
import AppKit

/// 画面左端に表示するフローティングサイドバー（格納ウィンドウ一覧）
///
/// 各モニター（NSScreen）の左端に NSPanel を使って常時表示する
final class StageSidebarController: NSObject {

    private var panels: [NSScreen: NSPanel] = [:]

    /// 全モニターにサイドバーを表示する
    @MainActor
    func show(windowManager: WindowManager) {
        hide() // 既存のサイドバーを一度クリーンアップ

        for screen in NSScreen.screens {
            let screenFrame = screen.visibleFrame

            let sidebarWidth: CGFloat = 180
            let sidebarHeight = screenFrame.height * 0.6
            let sidebarY = screenFrame.minY + (screenFrame.height - sidebarHeight) / 2

            let panelFrame = CGRect(
                x: screenFrame.minX,
                y: sidebarY,
                width: sidebarWidth,
                height: sidebarHeight
            )

            let panel = NSPanel(
                contentRect: panelFrame,
                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let sidebarView = StageSidebarView(screen: screen)
                .environmentObject(windowManager)
            let hosting = NSHostingView(rootView: sidebarView)
            panel.contentView = hosting

            panels[screen] = panel
            panel.orderFrontRegardless()
        }
    }

    /// すべてのサイドバーを非表示にする
    func hide() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

// MARK: - StageSidebarView (SwiftUI)

/// サイドバーのコンテンツ（SwiftUI）
struct StageSidebarView: View {
    @EnvironmentObject private var windowManager: WindowManager
    let screen: NSScreen
    @State private var hoveredWindowID: String?

    /// このスクリーンに所属する格納ウィンドウ
    private var stagedWindowsForScreen: [ManagedWindow] {
        let screenManager = ScreenManager()
        return windowManager.stagedWindows.filter { window in
            // 格納前のフレーム（なければ現在のフレーム）を用いて所属スクリーンを判定
            let frame = window.frameBeforeStaging ?? window.frame
            let winScreen = screenManager.screen(containingAXFrame: frame)
            return winScreen == screen
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー
            HStack {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(.secondary)
                Text("格納中")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
                .opacity(0.5)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(stagedWindowsForScreen) { window in
                        stagedWindowRow(window)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }

            if stagedWindowsForScreen.isEmpty {
                Spacer()
                Text("格納なし")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, x: 2, y: 0)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func stagedWindowRow(_ window: ManagedWindow) -> some View {
        Button {
            windowManager.unstageWindow(window)
        } label: {
            HStack(spacing: 8) {
                // アプリアイコン（アプリ名の頭文字を代替表示）
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.15))
                    Text(String(window.appName.prefix(1)))
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(window.appName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if !window.title.isEmpty && window.title != window.appName {
                        Text(window.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hoveredWindowID == window.id
                          ? Color.accentColor.opacity(0.12)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredWindowID = hovering ? window.id : nil
        }
        .animation(.easeInOut(duration: 0.15), value: hoveredWindowID)
    }
}
