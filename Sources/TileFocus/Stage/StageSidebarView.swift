import SwiftUI
import AppKit

/// ホバー検出用のカスタムコンテナビュー（NSHostingView をラップしてホバーイベントを確実にキャッチする）
class StageTopBarContainerView: NSView {
    private var trackingArea: NSTrackingArea?
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        
        // activeAlways: アプリが非アクティブでもマウスイベントを拾う
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: self.bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}

/// 画面上部に表示するホバー式のフローティングバー（格納ウィンドウ一覧）
class StageTopBarPanel: NSPanel {
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
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }

    // ★重要: 画面外へのはみ出し制限を無効化し、指定した画面外座標に正確にスライドして隠せるようにする
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - StageTopBarController

final class StageTopBarController: NSObject {
    private var panels: [NSScreen: StageTopBarPanel] = [:]
    
    private let barWidth: CGFloat = 600
    private let barHeight: CGFloat = 64
    private let visibleOffset: CGFloat = 8 // 隠れている時に画面内に露出させるピクセル数（ホバー検知用）
    
    @MainActor
    func show(windowManager: WindowManager) {
        hide() // 既存のパネルをクリア

        for screen in NSScreen.screens {
            let screenFrame = screen.visibleFrame
            
            // 初期状態（隠れている状態: 下端が screenFrame.maxY - visibleOffset になる位置）
            let initialX = screenFrame.minX + (screenFrame.width - barWidth) / 2
            let initialY = screenFrame.maxY - visibleOffset
            let panelFrame = CGRect(x: initialX, y: initialY, width: barWidth, height: barHeight)
            
            let panel = StageTopBarPanel(contentRect: panelFrame)
            
            // コンテナビューの作成
            let container = StageTopBarContainerView(frame: CGRect(x: 0, y: 0, width: barWidth, height: barHeight))
            container.autoresizingMask = [.width, .height]
            
            let topBarView = StageTopBarView(screen: screen)
                .environmentObject(windowManager)
            let hosting = NSHostingView(rootView: topBarView)
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            
            container.addSubview(hosting)
            panel.contentView = container
            
            // ホバーイベントの紐付け
            container.onMouseEnter = { [weak self, weak panel, weak windowManager] in
                guard let self, let panel else { return }
                Log.info("StageTopBarController", "mouseEntered 検知")
                windowManager?.isStagedWindowsBarExpanded = true
                self.updatePanelCollapseState(collapsed: false, panel: panel, screen: screen)
            }
            
            container.onMouseExit = { [weak self, weak panel, weak windowManager] in
                guard let self, let panel else { return }
                Log.info("StageTopBarController", "mouseExited 検知")
                windowManager?.isStagedWindowsBarExpanded = false
                self.updatePanelCollapseState(collapsed: true, panel: panel, screen: screen)
            }
            
            Log.info("StageTopBarController", "画面 '\(screen.localizedName)': visibleFrame=\(screenFrame), panelFrame=\(panelFrame)")
            
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
        
        // 展開時はメニューバーの直下（y = maxY - barHeight）
        // 格納時は下端が少しだけ露出（y = maxY - visibleOffset）
        let targetY = collapsed ? (screenFrame.maxY - visibleOffset) : (screenFrame.maxY - barHeight)
        
        let targetFrame = CGRect(x: x, y: targetY, width: barWidth, height: barHeight)
        
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
            // 展開時のみコンテンツを表示
            if windowManager.isStagedWindowsBarExpanded {
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
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
                )
                .transition(.opacity) // 滑らかな表示切り替え
            } else {
                // 非展開時は高さを維持するためのダミー領域（透明だがヒットテスト可能）
                Spacer()
                    .frame(height: 58)
            }
            
            // 下部中央のインジケーター（ホバー時のヒント。非展開時も極薄のガイド線として見える）
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(windowManager.isStagedWindowsBarExpanded ? 0.35 : 0.12))
                .frame(width: 40, height: 2)
                .padding(.bottom, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 普段は完全に透明（ヒットテスト用のアルファ）
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: windowManager.isStagedWindowsBarExpanded)
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
                        .foregroundStyle(.primary)
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
