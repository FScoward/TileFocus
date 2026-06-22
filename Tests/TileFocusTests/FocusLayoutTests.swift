import XCTest
@testable import TileFocus

final class FocusLayoutTests: XCTestCase {
    
    private let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private var originalWidthRatio: Double = 0.55

    override func setUp() {
        super.setUp()
        // 元の設定値を退避
        originalWidthRatio = AppSettings.shared.mainWidthRatio
    }

    override func tearDown() {
        // 設定値を元に戻す
        AppSettings.shared.mainWidthRatio = originalWidthRatio
        super.tearDown()
    }

    func testSingleWindowTakesFullScreen() {
        let layout = FocusLayout()
        let frames = layout.calculateFrames(windowCount: 1, screenFrame: screenFrame)
        
        XCTAssertEqual(frames.count, 1)
        
        let outer = layout.gap.outer
        let expectedFrame = CGRect(
            x: screenFrame.minX + outer,
            y: screenFrame.minY + outer,
            width: screenFrame.width - outer * 2,
            height: screenFrame.height - outer * 2
        )
        XCTAssertEqual(frames[0], expectedFrame)
    }

    func testLeftMainWidthRatioChange() {
        var layout = FocusLayout()
        layout.style = .leftMain
        
        let outer = layout.gap.outer
        let inner = layout.gap.inner
        let totalW = screenFrame.width - outer * 2
        
        // 1. 比率 0.50 のテスト
        AppSettings.shared.mainWidthRatio = 0.50
        var frames = layout.calculateFrames(windowCount: 2, screenFrame: screenFrame)
        XCTAssertEqual(frames.count, 2)
        
        // メインウィンドウ (i=0) の幅
        let expectedMainW50 = (totalW - inner) * 0.50
        XCTAssertEqual(frames[0].width, expectedMainW50, accuracy: 0.001)
        
        // サブウィンドウ (i=1) の幅
        let expectedSideW50 = (totalW - inner) - expectedMainW50
        XCTAssertEqual(frames[1].width, expectedSideW50, accuracy: 0.001)
        XCTAssertEqual(frames[1].origin.x, screenFrame.minX + outer + expectedMainW50 + inner, accuracy: 0.001)

        // 2. 比率 0.80 のテスト
        AppSettings.shared.mainWidthRatio = 0.80
        frames = layout.calculateFrames(windowCount: 2, screenFrame: screenFrame)
        
        let expectedMainW80 = (totalW - inner) * 0.80
        XCTAssertEqual(frames[0].width, expectedMainW80, accuracy: 0.001)
        
        let expectedSideW80 = (totalW - inner) - expectedMainW80
        XCTAssertEqual(frames[1].width, expectedSideW80, accuracy: 0.001)
    }

    func testRightMainWidthRatioChange() {
        var layout = FocusLayout()
        layout.style = .rightMain
        
        let outer = layout.gap.outer
        let inner = layout.gap.inner
        let totalW = screenFrame.width - outer * 2
        
        // 比率 0.60 のテスト
        AppSettings.shared.mainWidthRatio = 0.60
        let frames = layout.calculateFrames(windowCount: 2, screenFrame: screenFrame)
        XCTAssertEqual(frames.count, 2)
        
        let expectedMainW60 = (totalW - inner) * 0.60
        let expectedSideW60 = (totalW - inner) - expectedMainW60
        
        // 右メインなので、i=0 (メイン) は右側、i=1 (サブ) は左側 (startX) に配置されるはず
        XCTAssertEqual(frames[0].width, expectedMainW60, accuracy: 0.001)
        XCTAssertEqual(frames[0].origin.x, screenFrame.minX + outer + expectedSideW60 + inner, accuracy: 0.001)
        
        XCTAssertEqual(frames[1].width, expectedSideW60, accuracy: 0.001)
        XCTAssertEqual(frames[1].origin.x, screenFrame.minX + outer, accuracy: 0.001)
    }

    func testSplitCenteredWidthRatioChange() {
        var layout = FocusLayout()
        layout.style = .splitCentered
        
        let outer = layout.gap.outer
        let inner = layout.gap.inner
        let totalW = screenFrame.width - outer * 2
        
        // 比率 0.40 のテスト (サイド幅が 260px を下回らないように設定)
        AppSettings.shared.mainWidthRatio = 0.40
        
        // 3枚ウィンドウ (メイン2枚、サイド1枚) のテスト
        let frames = layout.calculateFrames(windowCount: 3, screenFrame: screenFrame)
        XCTAssertEqual(frames.count, 3)
        
        // 中央2つのメインウィンドウの合計幅
        let mainTotalW = (totalW - inner * 2) * 0.40
        let expectedMainW = (mainTotalW - inner) / 2
        
        XCTAssertEqual(frames[0].width, expectedMainW, accuracy: 0.001)
        XCTAssertEqual(frames[1].width, expectedMainW, accuracy: 0.001)
        
        // 両サイドウィンドウの幅 (全体からメイン合計幅を引いて2等分、ただし最小幅 260px)
        let remainingW = (totalW - inner * 2) - mainTotalW
        var expectedSideW = remainingW / 2
        if expectedSideW < 260 {
            expectedSideW = 260
        }
        
        // 3枚目のウィンドウはサイドバー (i=2)
        XCTAssertEqual(frames[2].width, expectedSideW, accuracy: 0.001)
    }
}
