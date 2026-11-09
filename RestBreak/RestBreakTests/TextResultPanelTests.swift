import AppKit
import SwiftUI
import Testing
@testable import RestBreak

/// 长截图提取文字可能有几百行：面板不能比屏幕高，文字在框里滚动
@MainActor
struct TextResultPanelTests {
    private func height(text: String, translation: TextResultModel.Translation = .none) -> CGFloat {
        let model = TextResultModel()
        model.text = text
        model.recognition = .done
        model.translation = translation
        let hosting = NSHostingController(rootView: TextResultView(model: model))
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.height
    }

    @Test func 很长的识别结果面板高度有上限() {
        let long = (0..<600).map { "第 \($0) 行：长截图提取出来的很多文字，需要在框里滚动查看" }.joined(separator: "\n")
        #expect(height(text: long) < 600)
        #expect(height(text: long, translation: .done(long)) < 760)
    }

    @Test func 短文字面板按内容大小() {
        let short = "一行字"
        let medium = (0..<8).map { "第 \($0) 行" }.joined(separator: "\n")
        #expect(height(text: short) < height(text: medium))
    }
}
