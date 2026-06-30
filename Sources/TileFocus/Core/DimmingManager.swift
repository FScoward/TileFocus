import Cocoa
import Combine

/// 選択したウィンドウ以外を暗くする（Dimming）機能を管理するクラス
@MainActor
final class DimmingManager {
    static let shared = DimmingManager()
    
    private var dimmingWindows: [NSScreen: DimmingWindow] = [:]
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // AppSettings の変更を監視
        AppSettings.shared.$isDimmingEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateDimmingState()
            }
            .store(in: &cancellables)
            
        AppSettings.shared.$dimmingOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] opacity in
                self?.updateOpacity(opacity)
            }
            .store(in: &cancellables)
            
        // ディスプレイ構成の変更を監視
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.recreateWindows()
            }
            .store(in: &cancellables)
    }
    
    /// Dimming状態を更新（ウィンドウの作成/破棄、表示/非表示）
    func updateDimmingState() {
        let isEnabled = AppSettings.shared.isDimmingEnabled
        let isModeActive = WindowManager.shared.currentMode != .off
        
        if isEnabled && isModeActive {
            setupWindows()
            showWindows()
            updateFocusedWindowRect()
        } else {
            hideWindows()
        }
    }
    
    private func setupWindows() {
        let screens = NSScreen.screens
        // 不要になったスクリーン用のウィンドウを削除
        for screen in Array(dimmingWindows.keys) {
            if !screens.contains(screen) {
                dimmingWindows[screen]?.close()
                dimmingWindows.removeValue(forKey: screen)
            }
        }
        
        // 新しいスクリーン用のウィンドウを作成
        for screen in screens {
            if dimmingWindows[screen] == nil {
                let window = DimmingWindow(screen: screen)
                dimmingWindows[screen] = window
            }
        }
    }
    
    private func showWindows() {
        for window in dimmingWindows.values {
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
    }
    
    private func hideWindows() {
        for window in dimmingWindows.values {
            window.orderOut(nil)
        }
    }
    
    private func recreateWindows() {
        hideWindows()
        dimmingWindows.values.forEach { $0.close() }
        dimmingWindows.removeAll()
        updateDimmingState()
    }
    
    private func updateOpacity(_ opacity: Double) {
        for window in dimmingWindows.values {
            window.setOpacity(opacity)
        }
    }
    
    /// フォーカスされたウィンドウのフレームを更新して切り抜く
    func updateFocusedWindowRect() {
        guard AppSettings.shared.isDimmingEnabled && WindowManager.shared.currentMode != .off else {
            hideWindows()
            return
        }
        
        // フォーカスされているウィンドウを取得
        guard let focusedID = WindowManager.shared.focusedWindowID,
              let focusedWindow = (WindowManager.shared.managedWindows + WindowManager.shared.stagedWindows).first(where: { $0.id == focusedID }) else {
            // フォーカスウィンドウがない場合は、画面全体を暗くしたままにする（切り抜き無し）
            for window in dimmingWindows.values {
                window.setTargetRect(nil)
            }
            setupWindows()
            showWindows()
            return
        }
        
        let axFrame = focusedWindow.frameBeforeStaging ?? focusedWindow.frame
        let screenManager = ScreenManager()
        let appKitFrame = screenManager.axToAppKit(axFrame)
        
        setupWindows() // ディスプレイ構成のずれ防止
        showWindows()
        
        for (screen, window) in dimmingWindows {
            // スクリーン座標系における相対座標を計算
            let localRect = CGRect(
                x: appKitFrame.origin.x - screen.frame.origin.x,
                y: appKitFrame.origin.y - screen.frame.origin.y,
                width: appKitFrame.width,
                height: appKitFrame.height
            )
            window.setTargetRect(localRect)
        }
    }
}

/// Dimmingを行うためのカスタムView
private final class DimmingView: NSView {
    var targetRect: CGRect? {
        didSet {
            if oldValue != targetRect {
                needsDisplay = true
            }
        }
    }
    
    var dimmingOpacity: CGFloat = 0.3 {
        didSet {
            if oldValue != dimmingOpacity {
                needsDisplay = true
            }
        }
    }
    
    override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        // 全体を半透明の黒で塗りつぶす
        context.setFillColor(NSColor.black.withAlphaComponent(dimmingOpacity).cgColor)
        context.fill(bounds)
        
        // ターゲット矩形があれば、その部分をクリアする
        if let target = targetRect {
            context.saveGState()
            context.setBlendMode(.clear)
            
            // 角丸ウィンドウの考慮
            let cornerRadius: CGFloat = 12.0
            let path = CGPath(roundedRect: target, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(path)
            context.fillPath()
            
            context.restoreGState()
        }
    }
}

/// 画面全体を覆い、フォーカスされたウィンドウ以外を暗くするウィンドウ
final class DimmingWindow: NSPanel {
    private let dimmingView: DimmingView
    
    init(screen: NSScreen) {
        let contentRect = CGRect(origin: .zero, size: screen.frame.size)
        self.dimmingView = DimmingView(frame: contentRect)
        self.dimmingView.dimmingOpacity = CGFloat(AppSettings.shared.dimmingOpacity)
        
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        
        self.level = .floating
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = false
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        // スクリーン全体にフィットさせる
        self.setFrame(screen.frame, display: true)
        
        self.contentView = dimmingView
    }
    
    func setTargetRect(_ rect: CGRect?) {
        dimmingView.targetRect = rect
    }
    
    func setOpacity(_ opacity: Double) {
        dimmingView.dimmingOpacity = CGFloat(opacity)
    }
}
