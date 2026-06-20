import SwiftUI
import AppKit

/// 画面左端に表示するフローティングサイドバー（格納ウィンドウ一覧）
///
/// NSPanel を使って他のアプリウィンドウの上に常時表示する
final class StageSidebarController: NSObject {

    private var panel: NSPanel?
    private var hostingView: Any?  // NSHostingView<some View> の型消去

    /// サイドバーを表示する
    @MainActor
    func show(windowManager: WindowManager) {
        if panel != nil { return }

        guard let screen = NSScreen.main else { return }
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

        let sidebarView = StageSidebarView()
            .environmentObject(windowManager)
        let hosting = NSHostingView(rootView: sidebarView)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting

        panel.orderFrontRegardless()
    }

    /// サイドバーを非表示にする
    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}

// MARK: - StageSidebarView (SwiftUI)

/// サイドバーのコンテンツ（SwiftUI）
struct StageSidebarView: View {
    @EnvironmentObject private var windowManager: WindowManager
    @State private var hoveredWindowID: String?

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
                    ForEach(windowManager.stagedWindows) { window in
                        stagedWindowRow(window)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }

            if windowManager.stagedWindows.isEmpty {
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
            if windowManager.currentMode == .stage {
                windowManager.switchStageActiveWindow(to: window.id)
            } else {
                windowManager.unstageWindow(window)
            }
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
