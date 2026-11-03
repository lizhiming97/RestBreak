// Axis extraction/reversal adapted from Caldis/Mos ScrollEvent.swift.
// CC BY-NC 4.0. See UPSTREAM.md.
import AppKit

public enum ScrollEventAdapter {
    public static let marker: Int64 = 0x4652494441594D
    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }

    /// 保守跳过连续输入与手势：触控板、Magic Mouse、已经被其他驱动平滑的事件原样通过。
    public static func isDiscreteWheel(_ event: CGEvent) -> Bool {
        !isSynthetic(event) && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
            && event.getIntegerValueField(.scrollWheelEventScrollPhase) == 0
            && event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0
            && event.getIntegerValueField(.scrollWheelEventScrollCount) == 0
    }

    public static func value(_ event: CGEvent, horizontal: Bool) -> Double {
        let fields: [CGEventField] = horizontal
            ? [.scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2]
            : [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1]
        return fields.map { event.getDoubleValueField($0) }.first { $0 != 0 } ?? 0
    }

    public static func reverse(_ event: CGEvent, horizontal: Bool) {
        let line: CGEventField = horizontal ? .scrollWheelEventDeltaAxis2 : .scrollWheelEventDeltaAxis1
        let fixed: CGEventField = horizontal ? .scrollWheelEventFixedPtDeltaAxis2 : .scrollWheelEventFixedPtDeltaAxis1
        let point: CGEventField = horizontal ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventPointDeltaAxis1
        // CoreGraphics 修改一种表示时会更新另一些字段，必须先快照再写回（与 Mos 一致）。
        let values = (event.getIntegerValueField(line), event.getDoubleValueField(fixed), event.getDoubleValueField(point))
        event.setIntegerValueField(line, value: -values.0)
        event.setDoubleValueField(fixed, value: -values.1)
        event.setDoubleValueField(point, value: -values.2)
    }

    public static func clear(_ event: CGEvent, horizontal: Bool) {
        let fields: [CGEventField] = horizontal
            ? [.scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2]
            : [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1]
        for field in fields { event.setDoubleValueField(field, value: 0) }
    }

    public static func frame(from original: CGEvent, y: Double, x: Double) -> CGEvent? {
        guard let event = original.copy() else { return nil }
        clear(event, horizontal: false); clear(event, horizontal: true)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        return event
    }
}

/// CGEvent 的 point delta 实际按整数保存；跨帧累计小数，避免平滑尾部逐帧被截断。
public struct PixelAccumulator {
    private var remainder = 0.0
    public init() {}
    public mutating func take(_ value: Double) -> Double {
        if remainder * value < 0 { remainder = 0 }
        let total = remainder + value
        let whole = total.rounded(.towardZero)
        remainder = total - whole
        return whole
    }
}
