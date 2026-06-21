import SwiftUI
import AppKit

/// 画面上部に表示するホバー式のフローティングバー（格納ウィンドウ一覧）
class StageTopBarPanel: NSPanel {
    private var trackingArea: NSTrackingArea?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        contentView?.addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}

// MARK: - StageTopBarController

final class StageTopBarController: NSObject {
    private var panels: [NSScreen: StageTopBarPanel] = [:]
    
    private let barWidth: CGFloat = 600
    private let barHeight: CGFloat = 64
    
    @MainActor
    func show(windowManager: WindowManager) {
        hide() // 既存のパネルをクリア

        for screen in NSScreen.screens {
            let screenFrame = screen.visibleFrame
            
            // 初期状態（折りたたまれた状態 = 上端に4pxだけ露出）
            let initialX = screenFrame.minX + (screenFrame.width - barWidth) / 2
            let initialY = screenFrame.maxY - 4
            let panelFrame = CGRect(x: initialX, y: initialY, width: barWidth, height: barHeight)
            
            let panel = StageTopBarPanel(contentRect: panelFrame)
            
            let topBarView = StageTopBarView(screen: screen)
                .environmentObject(windowManager)
            let hosting = NSHostingView(rootView: topBarView)
            panel.contentView = hosting
            
            // ホバーイベントの紐付け
            panel.onMouseEnter = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.updatePanelCollapseState(collapsed: false, panel: panel, screen: screen)
            }
            
            panel.onMouseExit = { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.updatePanelCollapseState(collapsed: true, panel: panel, screen: screen)
            }
            
            panels[screen] = panel
            panel.orderFrontRegardless()
        }
    }
    
    func hide() {
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
    
    @MainActor
    private func updatePanelCollapseState(collapsed: Bool, panel: StageTopBarPanel, screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let x = screenFrame.minX + (screenFrame.width - barWidth) / 2
        let y = collapsed ? (screenFrame.maxY - 4) : (screenFrame.maxY - barHeight)
        
        let targetFrame = CGRect(x: x, y: y, width: barWidth, height: barHeight)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }
}

// MARK: - StageTopBarView (SwiftUI)

struct StageTopBarView: View {
    @EnvironmentObject private var windowManager: WindowManager
    let screen: NSScreen
    @State private var hoveredWindowID: String?

    private var stagedWindowsForScreen: [ManagedWindow] {
        let screenManager = ScreenManager()
        return windowManager.stagedWindows.filter { window in
            let frame = window.frameBeforeStaging ?? window.frame
            let winScreen = screenManager.screen(containingAXFrame: frame)
            return winScreen == screen
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if stagedWindowsForScreen.isEmpty {
                    Spacer()
                    Text("格納中のウィンドウはありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(stagedWindowsForScreen) { window in
                                stagedWindowItem(window)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 58)
            
            // 下部中央のインジケーター（ホバー時のヒント）
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 40, height: 2)
                .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func stagedWindowItem(_ window: ManagedWindow) -> some View {
        Button {
            windowManager.unstageWindow(window)
        } label: {
            HStack(spacing: 6) {
                // アプリアイコンの代用
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.15))
                    Text(String(window.appName.prefix(1)))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 0) {
                    Text(window.appName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if !window.title.isEmpty && window.title != window.appName {
                        Text(window.title)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 90, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hoveredWindowID == window.id
                          ? Color.accentColor.opacity(0.12)
                          : Color.secondary.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredWindowID = hovering ? window.id : nil
        }
        .animation(.easeInOut(duration: 0.15), value: hoveredWindowID)
    }
}
