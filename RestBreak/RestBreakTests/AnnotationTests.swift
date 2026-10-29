import Foundation
import Testing
@testable import RestBreak

/// 截图标注的纯逻辑：⇧ 约束、命中、移动、编号、撤销重做
struct AnnotationTests {
    private func shape(_ tool: AnnotationTool, _ a: CGPoint, _ b: CGPoint,
                       size: StrokeSize = .medium) -> Annotation {
        Annotation(tool: tool, points: [a, b], style: ToolStyle(color: .red, size: size, mosaic: .pixelate))
    }

    // MARK: - ⇧ 约束

    @Test func 按住Shift矩形变正方形() {
        let end = Annotation.constrained(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30), tool: .rectangle)
        #expect(end == CGPoint(x: 50, y: 50))
        let up = Annotation.constrained(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: -30), tool: .ellipse)
        #expect(up == CGPoint(x: -30, y: -30))
    }

    @Test func 按住Shift箭头吸附45度() {
        let flat = Annotation.constrained(from: .zero, to: CGPoint(x: 100, y: 8), tool: .arrow)
        #expect(abs(flat.x - 100.32) < 0.1 && abs(flat.y) < 0.001)
        let diagonal = Annotation.constrained(from: .zero, to: CGPoint(x: 50, y: 46), tool: .highlighter)
        #expect(abs(diagonal.x - diagonal.y) < 0.001)
    }

    // MARK: - 包围框和命中

    @Test func 矩形只有边能点中() {
        let rect = shape(.rectangle, CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 160))
        #expect(rect.bounds == CGRect(x: 100, y: 100, width: 100, height: 60))
        #expect(rect.hitTest(CGPoint(x: 150, y: 101)))
        #expect(rect.hitTest(CGPoint(x: 203, y: 130)))
        #expect(!rect.hitTest(CGPoint(x: 150, y: 130)))   // 中间是空的
        #expect(!rect.hitTest(CGPoint(x: 260, y: 130)))
    }

    @Test func 椭圆按边命中() {
        let ellipse = shape(.ellipse, CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 100))
        #expect(ellipse.hitTest(CGPoint(x: 100, y: 1)))    // 顶点
        #expect(ellipse.hitTest(CGPoint(x: 199, y: 50)))   // 右端
        #expect(!ellipse.hitTest(CGPoint(x: 100, y: 50)))  // 圆心
        #expect(!ellipse.hitTest(CGPoint(x: 5, y: 5)))     // 包围框角落不在椭圆上
    }

    @Test func 马赛克整块都能点中() {
        let mosaic = shape(.mosaic, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100))
        #expect(mosaic.hitTest(CGPoint(x: 50, y: 50)))
    }

    @Test func 线条按距离命中() {
        let arrow = shape(.arrow, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        #expect(arrow.hitTest(CGPoint(x: 50, y: 5)))
        #expect(!arrow.hitTest(CGPoint(x: 50, y: 20)))
        var pen = shape(.pen, CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50))
        pen.points.append(CGPoint(x: 100, y: 0))
        #expect(pen.hitTest(CGPoint(x: 75, y: 26)))
        #expect(!pen.hitTest(CGPoint(x: 50, y: 0)))
    }

    @Test func 文字和序号按区域命中() {
        var text = Annotation(tool: .text, points: [CGPoint(x: 10, y: 10)], style: .default)
        text.textSize = CGSize(width: 80, height: 24)
        #expect(text.bounds == CGRect(x: 10, y: 10, width: 80, height: 24))
        #expect(text.hitTest(CGPoint(x: 50, y: 20)))
        let number = Annotation(tool: .number, points: [CGPoint(x: 100, y: 100)], style: .default, number: 1)
        #expect(number.hitTest(CGPoint(x: 108, y: 100)))
        #expect(!number.hitTest(CGPoint(x: 130, y: 100)))
    }

    @Test func 移动所有点() {
        let moved = shape(.arrow, CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)).moved(by: CGSize(width: 5, height: -5))
        #expect(moved.points == [CGPoint(x: 5, y: -5), CGPoint(x: 15, y: 5)])
    }

    @Test func 粗细档对应实际尺寸() {
        #expect(shape(.rectangle, .zero, .zero, size: .small).lineWidth == 2)
        #expect(shape(.rectangle, .zero, .zero, size: .large).lineWidth == 7)
        #expect(shape(.highlighter, .zero, .zero, size: .medium).lineWidth == 18)
        #expect(Annotation(tool: .text, points: [.zero], style: .default).fontSize == 20)
    }

    // MARK: - 文档：增删改、撤销重做、编号

    @Test func 点中最上面的标注() {
        var doc = AnnotationDocument()
        let below = shape(.mosaic, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100))
        let above = shape(.mosaic, CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150))
        doc.add(below)
        doc.add(above)
        #expect(doc.item(at: CGPoint(x: 75, y: 75))?.id == above.id)
        #expect(doc.item(at: CGPoint(x: 25, y: 25))?.id == below.id)
        #expect(doc.item(at: CGPoint(x: 300, y: 300)) == nil)
    }

    @Test func 撤销和重做() {
        var doc = AnnotationDocument()
        let a = shape(.arrow, .zero, CGPoint(x: 10, y: 0))
        doc.add(a)
        doc.update(a.id) { $0.style.color = .blue }
        #expect(doc.items.first?.style.color == .blue)
        doc.undo()
        #expect(doc.items.first?.style.color == .red)
        doc.undo()
        #expect(doc.items.isEmpty)
        #expect(!doc.canUndo && doc.canRedo)
        doc.redo()
        #expect(doc.items.count == 1)
        doc.remove(a.id)
        #expect(doc.items.isEmpty && !doc.canRedo)   // 新操作后不能再重做
    }

    @Test func 拖动移动只记一次撤销() {
        var doc = AnnotationDocument()
        let a = shape(.rectangle, .zero, CGPoint(x: 10, y: 10))
        doc.add(a)
        doc.beginTransient()
        doc.updateTransient { items in items[0] = items[0].moved(by: CGSize(width: 5, height: 0)) }
        doc.updateTransient { items in items[0] = items[0].moved(by: CGSize(width: 5, height: 0)) }
        doc.commitTransient()
        #expect(doc.items[0].points[0] == CGPoint(x: 10, y: 0))
        doc.undo()
        #expect(doc.items[0].points[0] == .zero)
    }

    @Test func 没动过的拖动不记撤销() {
        var doc = AnnotationDocument()
        doc.add(shape(.rectangle, .zero, CGPoint(x: 10, y: 10)))
        doc.beginTransient()
        doc.commitTransient()
        doc.undo()
        #expect(doc.items.isEmpty)   // 撤销的是「添加」，说明拖动没有多记一步
    }

    @Test func 序号取最大值加一_删除不重排() {
        var doc = AnnotationDocument()
        #expect(doc.nextNumber() == 1)
        doc.add(Annotation(tool: .number, points: [.zero], style: .default, number: 1))
        doc.add(Annotation(tool: .number, points: [.zero], style: .default, number: 3))
        #expect(doc.nextNumber() == 4)
    }

    // MARK: - 设置

    @Test func 工具样式默认值和旧设置兼容() throws {
        #expect(AppSettings.default.style(for: .arrow) == ToolStyle.default)
        var settings = AppSettings.default
        settings.annotationStyles[.arrow] = ToolStyle(color: .blue, size: .large, mosaic: .pixelate)
        let loaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(loaded.style(for: .arrow).color == .blue)

        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.default)) as? [String: Any])
        json.removeValue(forKey: "annotationStyles")
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.annotationStyles.isEmpty)
    }
}
