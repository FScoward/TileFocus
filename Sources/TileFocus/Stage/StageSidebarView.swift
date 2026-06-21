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
    
    private let barWidth: CGFloat = 620
    private let collapsedHeight: CGFloat = 4
    private let visibleOffset: CGFloat = 8 // 隠れている時に画面内に露出させるピクセル数（ホバー検知用）
    
    @MainActor
    func show(windowManager: WindowManager) {
        hide() // 既存のパネルをクリア

        for screen in NSScreen.screens {
            let screenFrame = screen.visibleFrame
            
            // 初期状態（隠れている状態: 下端が screenFrame.maxY - visibleOffset になる位置）
            let initialX = screenFrame.minX + (screenFrame.width - barWidth) / 2
            let initialY = screenFrame.maxY - visibleOffset
            // 初期高さは collapsedHeight(4px)
            let panelFrame = CGRect(x: initialX, y: initialY, width: barWidth, height: collapsedHeight)
            
            let panel = StageTopBarPanel(contentRect: panelFrame)
            
            // コンテナビューの作成
            let container = StageTopBarContainerView(frame: CGRect(x: 0, y: 0, width: barWidth, height: collapsedHeight))
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
                guard let self, let panel, let windowManager else { return }
                Log.info("StageTopBarController", "mouseEntered 検知")
                windowManager.isStagedWindowsBarExpanded = true
                self.updatePanelCollapseState(collapsed: false, panel: panel, screen: screen, windowManager: windowManager)
            }
            
            container.onMouseExit = { [weak self, weak panel, weak windowManager] in
                guard let self, let panel, let windowManager else { return }
                Log.info("StageTopBarController", "mouseExited 検知")
                windowManager.isStagedWindowsBarExpanded = false
                self.updatePanelCollapseState(collapsed: true, panel: panel, screen: screen, windowManager: windowManager)
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
    private func updatePanelCollapseState(collapsed: Bool, panel: StageTopBarPanel, screen: NSScreen, windowManager: WindowManager) {
        let screenFrame = screen.visibleFrame
        let x = screenFrame.minX + (screenFrame.width - barWidth) / 2
        
        let targetHeight: CGFloat
        if collapsed {
            targetHeight = collapsedHeight
        } else {
            // そのスクリーンに属するウィンドウ数を動的に取得して高さを計算
            let screenManager = ScreenManager()
            let all = windowManager.managedWindows + windowManager.stagedWindows
            let count = all.filter { window in
                let frame = window.frameBeforeStaging ?? window.frame
                return screenManager.screen(containingAXFrame: frame) == screen
            }.count
            
            // 4列グリッドの行数
            let rows = max(1, Int(ceil(Double(count) / 4.0)))
            // 1行あたり 30px + 行間 6px、上下パディング計 20px
            let gridHeight = CGFloat(rows * 30 + (rows - 1) * 6 + 20)
            
            // Focus Mode のときはレイアウト切り替えツールバーの高さ（34px）を追加
            let toolbarHeight: CGFloat = (windowManager.currentMode == .focus) ? 34 : 0
            targetHeight = gridHeight + toolbarHeight
        }
        
        let targetY = collapsed ? (screenFrame.maxY - visibleOffset) : (screenFrame.maxY - targetHeight)
        let targetFrame = CGRect(x: x, y: targetY, width: barWidth, height: targetHeight)
        
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

    /// このスクリーンに所属するすべてのウィンドウ（表示中 + 格納中）
    /// 位置を固定するため、アプリ名・タイトル順にソートします
    private var allWindowsForScreen: [ManagedWindow] {
        let screenManager = ScreenManager()
        let all = windowManager.managedWindows + windowManager.stagedWindows
        return all.filter { window in
            let frame = window.frameBeforeStaging ?? window.frame
            let winScreen = screenManager.screen(containingAXFrame: frame)
            return winScreen == screen
        }.sorted { w1, w2 in
            if w1.appName != w2.appName {
                return w1.appName < w2.appName
            }
            return w1.title < w2.title
        }
    }

    // 1行4列のグリッドレイアウト
    private let columns = [
        GridItem(.fixed(140), spacing: 6),
        GridItem(.fixed(140), spacing: 6),
        GridItem(.fixed(140), spacing: 6),
        GridItem(.fixed(140), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 展開時のみコンテンツを表示
            if windowManager.isStagedWindowsBarExpanded {
                VStack(spacing: 0) {
                    // Focus Mode の場合のみレイアウトスタイル切り替えツールバーを表示
                    if windowManager.currentMode == .focus {
                        HStack(spacing: 8) {
                            Text("レイアウト:")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                            
                            Spacer()
                            
                            ForEach(FocusStyle.allCases) { style in
                                Button {
                                    windowManager.focusStyle = style
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: style.iconName)
                                            .font(.system(size: 9))
                                        Text(style.displayName)
                                            .font(.system(size: 10))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(windowManager.focusStyle == style ? Color.purple.opacity(0.15) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(windowManager.focusStyle == style ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 0.5)
                                    )
                                    .foregroundStyle(windowManager.focusStyle == style ? Color.purple : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        
                        Divider()
                            .padding(.horizontal, 10)
                            .padding(.bottom, 5)
                    }

                    if allWindowsForScreen.isEmpty {
                        Text("起動中のウィンドウはありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 30)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(allWindowsForScreen) { window in
                                windowItem(window)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 3)
                )
                .transition(.opacity) // 滑らかな表示切り替え
            } else {
                Spacer()
            }
            
            // 下部中央のインジゲーター（ホバー時のヒント。非展開時も極小のガイド線として見える）
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(windowManager.isStagedWindowsBarExpanded ? 0.35 : 0.12))
                .frame(width: 40, height: 2)
                .padding(.bottom, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.18), value: windowManager.isStagedWindowsBarExpanded)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func windowItem(_ window: ManagedWindow) -> some View {
        let isStaged = windowManager.stagedWindows.contains(where: { $0.id == window.id })
        // 現在フォーカス（メイン）されているかどうか
        let isMaster = windowManager.focusedWindowID == window.id
        
        HStack(spacing: 2) {
            // 1. 左側: 表示/非表示トグルボタン
            Button {
                if isStaged {
                    windowManager.unstageWindow(window)
                } else {
                    windowManager.stageWindow(window)
                }
            } label: {
                HStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isStaged ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.15))
                        Text(String(window.appName.prefix(1)))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(isStaged ? Color.secondary : Color.accentColor)
                    }
                    .frame(width: 16, height: 16)

                    Text(window.appName)
                        .font(.system(size: 10, weight: isStaged ? .regular : .semibold))
                        .foregroundStyle(isStaged ? .secondary : .primary)
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                    
                    Image(systemName: isStaged ? "eye.slash" : "eye.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(isStaged ? Color.secondary.opacity(0.4) : Color.accentColor)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            hoveredWindowID == window.id
                            ? (isStaged ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.15))
                            : (isStaged ? Color.clear : Color.accentColor.opacity(0.06))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isStaged ? Color.clear : Color.accentColor.opacity(0.2), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredWindowID = hovering ? window.id : nil
            }

            // 2. 右側: メイン（マスター）に設定する王冠ボタン
            Button {
                if isStaged {
                    windowManager.unstageWindow(window)
                }
                windowManager.switchFocusedWindow(to: window.id)
            } label: {
                Image(systemName: isMaster ? "crown.fill" : "crown")
                    .font(.system(size: 9))
                    .foregroundStyle(isMaster ? Color.yellow : Color.secondary.opacity(0.4))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isMaster ? Color.yellow.opacity(0.15) : Color.clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMaster ? Color.yellow.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isMaster ? Color.yellow.opacity(0.25) : Color.clear, lineWidth: 0.5)
        )
        .frame(width: 140) // グリッドの各アイテム幅を140pxに固定
    }
}
