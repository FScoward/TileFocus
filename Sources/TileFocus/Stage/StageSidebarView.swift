import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    private var collapseWorkItems: [NSScreen: DispatchWorkItem] = [:]
    
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
            
            // NSVisualEffectView を作成して背景に設定（本物のすりガラス効果）
            let effectView = NSVisualEffectView(frame: container.bounds)
            effectView.autoresizingMask = [.width, .height]
            effectView.blendingMode = .behindWindow // ウィンドウの背後をブレンド
            effectView.material = .hudWindow // HUD風のクールなマテリアル
            effectView.state = .active
            effectView.alphaValue = 0.85 // 本格的な透過効果のためにガラスのアルファを少し下げる
            
            // 角丸を適用
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = 12
            effectView.layer?.masksToBounds = true
            
            let topBarView = StageTopBarView(screen: screen)
                .environmentObject(windowManager)
            let hosting = NSHostingView(rootView: topBarView)
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            
            container.addSubview(effectView)
            container.addSubview(hosting)
            panel.contentView = container
            
            // ホバーイベントの紐付け
            container.onMouseEnter = { [weak self, weak panel, weak windowManager] in
                guard let self, let panel, let windowManager else { return }
                Log.info("StageTopBarController", "mouseEntered 検知")
                
                // 閉じる予定のタスクがあれば即座にキャンセルして開きっぱなしにする
                self.collapseWorkItems[screen]?.cancel()
                self.collapseWorkItems[screen] = nil
                
                windowManager.isStagedWindowsBarExpanded = true
                self.updatePanelCollapseState(collapsed: false, panel: panel, screen: screen, windowManager: windowManager)
            }
            
            container.onMouseExit = { [weak self, weak panel, weak windowManager] in
                guard let self, let panel, let windowManager else { return }
                Log.info("StageTopBarController", "mouseExited 検知")
                
                // 誤検知やチャタリングを防ぐため、閉じる処理に 0.2 秒の遅延バッファを持たせる
                self.collapseWorkItems[screen]?.cancel()
                let workItem = DispatchWorkItem { [weak self, weak panel, weak windowManager] in
                    guard let self, let panel, let windowManager else { return }
                    Log.info("StageTopBarController", "mouseExited 確定、バーを閉じます")
                    windowManager.isStagedWindowsBarExpanded = false
                    self.updatePanelCollapseState(collapsed: true, panel: panel, screen: screen, windowManager: windowManager)
                }
                self.collapseWorkItems[screen] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            }
            
            Log.info("StageTopBarController", "画面 '\(screen.localizedName)': visibleFrame=\(screenFrame), panelFrame=\(panelFrame)")
            
            panels[screen] = panel
            panel.orderFrontRegardless()
        }
    }
    
    func hide() {
        for workItem in collapseWorkItems.values {
            workItem.cancel()
        }
        collapseWorkItems.removeAll()

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

// MARK: - LiquidBlobView (SwiftUI)

struct LiquidBlobView: View {
    @State private var animate = false
    let color: Color
    let width: CGFloat
    let blurRadius: CGFloat
    let startOffsetX: CGFloat
    let startOffsetY: CGFloat
    let endOffsetX: CGFloat
    let endOffsetY: CGFloat
    let speed: Double

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: width)
            .blur(radius: blurRadius)
            .offset(
                x: animate ? endOffsetX : startOffsetX,
                y: animate ? endOffsetY : startOffsetY
            )
            .scaleEffect(animate ? 1.15 : 0.85)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: speed)
                    .repeatForever(autoreverses: true)
                ) {
                    animate = true
                }
            }
    }
}

// MARK: - StageTopBarView (SwiftUI)

struct StageTopBarView: View {
    @EnvironmentObject private var windowManager: WindowManager
    let screen: NSScreen
    @State private var hoveredWindowID: String?
    @State private var draggedWindow: ManagedWindow?
    @State private var tempWindows: [ManagedWindow] = []
    @State private var draggingWindowID: String? = nil
    @State private var dragStartIndex: Int? = nil
    @State private var hoveringIndex: Int? = nil
    @State private var dragOffset: CGSize = .zero
    private let overlayManager = LayoutOverlayManager()


    /// このスクリーンに所属するすべてのウィンドウ（表示中 + 格納中）
    /// 王冠（マスターウィンドウ）を常に先頭にし、残りはユーザー定義のカスタムオーダー（無ければアプリ名・タイトル順）でソートします
    private var allWindowsForScreen: [ManagedWindow] {
        let screenManager = ScreenManager()
        let all = windowManager.managedWindows + windowManager.stagedWindows
        let filtered = all.filter { window in
            let frame = window.frameBeforeStaging ?? window.frame
            let winScreen = screenManager.screen(containingAXFrame: frame)
            return winScreen == screen
        }
        
        var result = filtered
        if let masterID = windowManager.masterWindow?.id,
           let masterIndex = result.firstIndex(where: { $0.id == masterID }) {
            let master = result.remove(at: masterIndex)
            let sortedOthers = result.sorted { w1, w2 in
                let idx1 = windowManager.customWindowOrder.firstIndex(of: w1.id)
                let idx2 = windowManager.customWindowOrder.firstIndex(of: w2.id)
                
                switch (idx1, idx2) {
                case (.some(let i1), .some(let i2)):
                    return i1 < i2
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    if w1.appName != w2.appName {
                        return w1.appName < w2.appName
                    }
                    return w1.title < w2.title
                }
            }
            return [master] + sortedOthers
        } else {
            return result.sorted { w1, w2 in
                let idx1 = windowManager.customWindowOrder.firstIndex(of: w1.id)
                let idx2 = windowManager.customWindowOrder.firstIndex(of: w2.id)
                
                switch (idx1, idx2) {
                case (.some(let i1), .some(let i2)):
                    return i1 < i2
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    if w1.appName != w2.appName {
                        return w1.appName < w2.appName
                    }
                    return w1.title < w2.title
                }
            }
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
                                    windowManager.setFocusStyle(style, for: screen)
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
                                            .fill(windowManager.focusStyle(for: screen) == style ? Color.purple.opacity(0.15) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(windowManager.focusStyle(for: screen) == style ? Color.purple.opacity(0.3) : Color.clear, lineWidth: 0.5)
                                    )
                                    .foregroundStyle(windowManager.focusStyle(for: screen) == style ? Color.purple : Color.primary)
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

                    if tempWindows.isEmpty {
                        Text("起動中のウィンドウはありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 30)
                    } else {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(tempWindows, id: \.id) { window in
                                if let index = tempWindows.firstIndex(where: { $0.id == window.id }) {
                                    windowItem(window, index: index)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                    }
                }
                .background(
                    ZStack {
                        // リキッドグラスの背後のカラフルな液体要素 (Liquid Blobs)
                        if windowManager.isStagedWindowsBarExpanded {
                            GeometryReader { geo in
                                ZStack {
                                    // 左側の紫のBlob (ゆっくりうねる)
                                    LiquidBlobView(
                                        color: Color.purple.opacity(0.35),
                                        width: geo.size.width * 0.45,
                                        blurRadius: 30,
                                        startOffsetX: -geo.size.width * 0.15,
                                        startOffsetY: -geo.size.height * 0.25,
                                        endOffsetX: -geo.size.width * 0.05,
                                        endOffsetY: -geo.size.height * 0.15,
                                        speed: 5.0
                                    )
                                    .blendMode(.plusLighter)
                                    
                                    // 右側の青いBlob (逆方向にうねる)
                                    LiquidBlobView(
                                        color: Color.blue.opacity(0.32),
                                        width: geo.size.width * 0.4,
                                        blurRadius: 25,
                                        startOffsetX: geo.size.width * 0.55,
                                        startOffsetY: geo.size.height * 0.15,
                                        endOffsetX: geo.size.width * 0.45,
                                        endOffsetY: geo.size.height * 0.05,
                                        speed: 6.2
                                    )
                                    .blendMode(.plusLighter)

                                    // 中央のピンクのBlob (ゆっくり拡大縮小)
                                    LiquidBlobView(
                                        color: Color.pink.opacity(0.25),
                                        width: geo.size.width * 0.3,
                                        blurRadius: 22,
                                        startOffsetX: geo.size.width * 0.15,
                                        startOffsetY: -geo.size.height * 0.15,
                                        endOffsetX: geo.size.width * 0.25,
                                        endOffsetY: -geo.size.height * 0.05,
                                        speed: 4.5
                                    )
                                    .blendMode(.plusLighter)
                                }
                            }
                        }
                        
                        // 最前面のガラスプレート (NSVisualEffectView の上にあるため、極めて薄いホワイトのハイライトグラデーションにして二重ぼかしを防ぐ)
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.04),
                                        Color.white.opacity(0.01)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
                    .overlay(
                        // 外側の極細のガラス反射枠
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.25),
                                        Color.white.opacity(0.05),
                                        Color.black.opacity(0.15)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
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
        .onAppear {
            tempWindows = allWindowsForScreen
        }
        .onChange(of: allWindowsForScreen) { newValue in
            if draggingWindowID == nil {
                tempWindows = newValue
            }
        }
        .onChange(of: draggedWindow) { newValue in
            if let _ = newValue {
                overlayManager.showOverlays(for: tempWindows, screen: screen, focusedID: windowManager.focusedWindowID)
            } else {
                overlayManager.hideOverlays()
            }
        }
        .onChange(of: windowManager.isStagedWindowsBarExpanded) { expanded in
            if !expanded {
                overlayManager.hideOverlays()
                draggedWindow = nil
            }
        }
        .onDisappear {
            overlayManager.hideOverlays()
            draggedWindow = nil
        }
    }

    /// ドラッグ中のカードの位置を、マウス移動量に追随させる
    private func correctedDragOffset(for windowID: String) -> CGSize {
        guard draggingWindowID == windowID else {
            return .zero
        }
        return dragOffset
    }

    /// ドラッグ中のカードを避けるために、他のカードをスライドさせるオフセットを算出する
    private func displacementOffset(for windowID: String) -> CGSize {
        guard let draggingWindowID = draggingWindowID,
              draggingWindowID != windowID,
              let startIdx = dragStartIndex,
              let targetIdx = hoveringIndex,
              let itemIdx = tempWindows.firstIndex(where: { $0.id == windowID }) else {
            return .zero
        }
        
        guard startIdx != targetIdx else { return .zero }
        
        let colWidth: CGFloat = 146
        let rowHeight: CGFloat = 36
        
        if startIdx < targetIdx {
            // ドラッグ中カードが後ろへ移動：startIdx < i <= targetIdx のカードが前にずれる (インデックス - 1)
            if itemIdx > startIdx && itemIdx <= targetIdx {
                if itemIdx % 4 == 0 {
                    return CGSize(width: colWidth * 3, height: -rowHeight)
                } else {
                    return CGSize(width: -colWidth, height: 0)
                }
            }
        } else {
            // ドラッグ中カードが前へ移動：targetIdx <= i < startIdx のカードが後ろにずれる (インデックス + 1)
            if itemIdx >= targetIdx && itemIdx < startIdx {
                if itemIdx % 4 == 3 {
                    return CGSize(width: -colWidth * 3, height: rowHeight)
                } else {
                    return CGSize(width: colWidth, height: 0)
                }
            }
        }
        
        return .zero
    }

    @ViewBuilder
    private func windowItem(_ window: ManagedWindow, index: Int) -> some View {
        let isStaged = windowManager.stagedWindows.contains(where: { $0.id == window.id })
        // 現在マスター（メイン）に設定されているかどうか
        let isMaster = windowManager.masterWindow?.id == window.id

        // 型推論エラーを避けるためにスタイル変数を切り出し
        let appLetterBg = isStaged ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.15)
        let appLetterFg = isStaged ? Color.secondary : Color.accentColor
        
        let appNameWeight: Font.Weight = isStaged ? .regular : (isMaster ? .bold : .semibold)
        let appNameFg = isStaged ? Color.secondary : Color.primary
        
        let crownFg = isMaster ? Color.yellow : (isStaged ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.7))
        
        let isHovered = hoveredWindowID == window.id
        
        // ウィンドウの物理的な画面位置を判定
        let positionLabel: String = {
            if isStaged { return "格納" }
            if isMaster { return "メイン" }
            let screenFrame = screen.frame
            let winFrame = window.frameBeforeStaging ?? window.frame
            let winMidX = winFrame.midX
            let screenMidX = screenFrame.midX
            if winMidX < screenMidX - 50 {
                return "左"
            } else if winMidX > screenMidX + 50 {
                return "右"
            } else {
                return "メイン"
            }
        }()
        
        let positionColor: Color = {
            if isStaged { return Color.secondary }
            if isMaster { return Color.orange }
            let screenFrame = screen.frame
            let winFrame = window.frameBeforeStaging ?? window.frame
            let winMidX = winFrame.midX
            let screenMidX = screenFrame.midX
            if winMidX < screenMidX - 50 {
                return Color.blue
            } else if winMidX > screenMidX + 50 {
                return Color.purple
            } else {
                return Color.orange
            }
        }()

        // --- リキッドグラス効果のためのグラデーション定義 ---
        let hoverGradient = LinearGradient(
            colors: [
                Color.purple.opacity(0.18),
                Color.blue.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        let masterGradient = LinearGradient(
            colors: [
                Color.yellow.opacity(0.18),
                Color.orange.opacity(0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        let normalGradient = LinearGradient(
            colors: [
                Color.white.opacity(isStaged ? 0.015 : 0.04),
                Color.white.opacity(isStaged ? 0.005 : 0.015)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        
        // ガラスの反射を感じさせる細い枠線
        let borderGradient = LinearGradient(
            colors: [
                Color.white.opacity(isHovered ? 0.35 : 0.15),
                Color.white.opacity(0.05),
                Color.black.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        let masterBorderGradient = LinearGradient(
            colors: [
                Color.yellow.opacity(0.4),
                Color.yellow.opacity(0.1),
                Color.clear
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        
        let itemContent = HStack(spacing: 2) {
            // 1. 左側: メイン（マスター）に設定するボタン（クリックのデフォルト動作）
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(appLetterBg)
                    Text(String(window.appName.prefix(1)))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(appLetterFg)
                }
                .frame(width: 16, height: 16)

                Text(window.appName)
                    .font(.system(size: 10, weight: appNameWeight))
                    .foregroundStyle(appNameFg)
                    .lineLimit(1)
                
                // 位置インジケータバッジ
                Text(positionLabel)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 0.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(positionColor.opacity(0.12))
                    )
                    .foregroundStyle(positionColor)
                
                Spacer(minLength: 0)
                
                // 状態を示す王冠アイコン
                Image(systemName: isMaster ? "crown.fill" : "crown")
                    .font(.system(size: 8))
                    .foregroundStyle(crownFg)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                ZStack {
                    // ガラスのすりガラス背景
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.ultraThinMaterial)
                    
                    // ホバー時・マスター時の有機的なリキッドグラデーション
                    if isMaster {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(masterGradient)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(hoverGradient)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(normalGradient)
                    }
                }
            )
            .overlay(
                // ガラスの反射を感じさせるシャープなボーダー
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isMaster ? masterBorderGradient : borderGradient, lineWidth: 0.8)
            )
            .shadow(
                color: isHovered ? (isMaster ? Color.yellow.opacity(0.12) : Color.purple.opacity(0.12)) : Color.clear,
                radius: 3,
                x: 0,
                y: 1.5
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65, blendDuration: 0), value: isHovered)
            .contentShape(Rectangle())
            .onTapGesture {
                if isStaged {
                    windowManager.unstageWindow(window)
                }
                windowManager.setMasterWindow(to: window.id)
            }
            .onHover { hovering in
                hoveredWindowID = hovering ? window.id : nil
            }

            // 2. 右側: 表示/非表示トグルボタン（サブ）
            Image(systemName: isStaged ? "eye.slash" : "eye.fill")
                .font(.system(size: 9))
                .foregroundStyle(isStaged ? Color.secondary.opacity(0.4) : Color.accentColor)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isStaged ? Color.clear : Color.accentColor.opacity(0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if isStaged {
                        windowManager.unstageWindow(window)
                    } else {
                        windowManager.stageWindow(window)
                    }
                }
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
        .contentShape(Rectangle())

        let isDraggingThis = draggingWindowID == window.id
        let offset = isDraggingThis ? correctedDragOffset(for: window.id) : displacementOffset(for: window.id)

        ZStack(alignment: .topLeading) {
            itemContent
            
            // インデックスバッジ（ドラッグ中もカードと一緒に移動し、常に最前面に表示）
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(window.id == windowManager.focusedWindowID ? Color.yellow : Color.purple)
                )
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                .offset(x: -4, y: -4)
        }
        .offset(offset)
        .zIndex(isDraggingThis ? 100 : (draggingWindowID != nil ? 10 : 1))
        .opacity(isDraggingThis ? 0.6 : (draggingWindowID != nil && draggedWindow?.id == window.id ? 0.35 : 1.0))
        .gesture(
            DragGesture(minimumDistance: 5)
                .onChanged { value in
                    if dragStartIndex == nil {
                         if let idx = tempWindows.firstIndex(where: { $0.id == window.id }) {
                             dragStartIndex = idx
                             hoveringIndex = idx
                             draggingWindowID = window.id
                             draggedWindow = window
                         }
                    }
                    
                    dragOffset = value.translation
                    
                    guard let startIdx = dragStartIndex else { return }
                    
                    let colWidth: CGFloat = 146
                    let rowHeight: CGFloat = 36
                    
                    let startCol = startIdx % 4
                    let startRow = startIdx / 4
                    
                    let deltaCol = Int(round(value.translation.width / colWidth))
                    let deltaRow = Int(round(value.translation.height / rowHeight))
                    
                    let targetCol = max(0, min(3, startCol + deltaCol))
                    let targetRow = max(0, startRow + deltaRow)
                    let targetIndex = min(tempWindows.count - 1, max(0, targetRow * 4 + targetCol))
                    
                    if targetIndex != hoveringIndex {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            hoveringIndex = targetIndex
                        }
                    }
                }
                .onEnded { value in
                    Log.info("StageTopBarView", "DragGesture onEnded: startIdx=\(dragStartIndex.map(String.init) ?? "nil"), hoveringIndex=\(hoveringIndex.map(String.init) ?? "nil")")
                    if let targetIdx = hoveringIndex, let startIdx = dragStartIndex, targetIdx != startIdx {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            let moving = tempWindows.remove(at: startIdx)
                            tempWindows.insert(moving, at: targetIdx)
                        }
                        
                        let targetIDs = Set(tempWindows.map { $0.id })
                        var currentOrder = windowManager.customWindowOrder
                        
                        let insertIndex = currentOrder.firstIndex { targetIDs.contains($0) } ?? currentOrder.count
                        currentOrder.removeAll { targetIDs.contains($0) }
                        currentOrder.insert(contentsOf: tempWindows.map { $0.id }, at: insertIndex)
                        
                        if let newMaster = tempWindows.first {
                            Log.info("StageTopBarView", "Switching master to newMaster: \(newMaster.appName) (\(newMaster.id))")
                            windowManager.switchFocusedWindow(to: newMaster.id)
                        }
                        
                        windowManager.customWindowOrder = currentOrder
                    } else {
                        Log.info("StageTopBarView", "DragGesture ended without order change.")
                    }
                    
                    draggingWindowID = nil
                    dragStartIndex = nil
                    hoveringIndex = nil
                    dragOffset = .zero
                    draggedWindow = nil
                }
        )
    }
}



// MARK: - Layout Window Overlay

class WindowNumberOverlayPanel: NSPanel {
    init(frame: NSRect, number: Int) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: OverlayNumberView(number: number))
        hosting.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
    }
}

struct OverlayNumberView: View {
    let number: Int
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.65))
                .frame(width: 80, height: 80)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 3)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            
            Text("\(number)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
class LayoutOverlayManager {
    private var overlayPanels: [WindowNumberOverlayPanel] = []
    private let screenManager = ScreenManager()

    func showOverlays(for windows: [ManagedWindow], screen: NSScreen, focusedID: String?) {
        hideOverlays()

        for (index, window) in windows.enumerated() {
            let windowFrame = window.frameBeforeStaging ?? window.frame
            
            // 対象スクリーンにあるウィンドウのみ表示する
            let winScreen = screenManager.screen(containingAXFrame: windowFrame)
            guard winScreen == screen else { continue }
            
            let cocoaFrame = screenManager.axToAppKit(windowFrame)

            // ウィンドウの中央に配置
            let panelSize: CGFloat = 120
            let centerX = cocoaFrame.midX - panelSize / 2
            let centerY = cocoaFrame.midY - panelSize / 2
            let panelFrame = CGRect(x: centerX, y: centerY, width: panelSize, height: panelSize)

            let panel = WindowNumberOverlayPanel(frame: panelFrame, number: index + 1)
            overlayPanels.append(panel)
            panel.orderFrontRegardless()
        }
    }

    func hideOverlays() {
        for panel in overlayPanels {
            panel.orderOut(nil)
        }
        overlayPanels.removeAll()
    }
}

// MARK: - DummyDropDelegate




