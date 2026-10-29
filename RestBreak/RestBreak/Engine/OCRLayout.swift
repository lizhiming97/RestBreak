import Foundation

/// OCR 识别出的一行文字。frame 是图像里的位置（左上角原点，单位随意，只要一致）
struct RecognizedLine: Equatable, Sendable {
    var text: String
    var frame: CGRect
}

/// 把 OCR 识别出的一行行文字，按原图的位置重新排成文本：
/// - 从上到下；同一行里的几段（如「标题      39s」）从左到右用两个空格连起来
/// - 两行之间空隙明显大于行高时，当作新段落，中间空一行
enum OCRLayout {
    static func text(from lines: [RecognizedLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let heights = lines.map(\.frame.height).sorted()
        let typicalHeight = heights[heights.count / 2]

        // 先按纵向中心排序，再把中心离得很近的归为同一行
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = rows.last?.last,
               abs(line.frame.midY - last.frame.midY) < min(line.frame.height, last.frame.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }

        var result = ""
        var previousBottom: CGFloat?
        for row in rows {
            let top = row.map(\.frame.minY).min() ?? 0
            if let previousBottom {
                result += top - previousBottom > typicalHeight * 0.8 ? "\n\n" : "\n"
            }
            result += row.sorted { $0.frame.minX < $1.frame.minX }.map(\.text).joined(separator: "  ")
            previousBottom = row.map(\.frame.maxY).max()
        }
        return result
    }

    /// 面板底部显示的「N 行 · N 字」：空行不算行，换行不算字
    static func stats(_ text: String) -> (lines: Int, characters: Int) {
        let lines = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return (lines.count, text.filter { $0 != "\n" }.count)
    }
}
