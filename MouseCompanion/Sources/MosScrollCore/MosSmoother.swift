// Adapted from Caldis/Mos ScrollPoster.update/processing (2020-2026).
// CC BY-NC 4.0; attribution and modification record in UPSTREAM.md.
import Foundation

/// 保留 Mos 的同向累积、反向重置、插值及曲线滤波；运行环境由星期五组件提供。
public final class MosSmoother {
    private var current = (y: 0.0, x: 0.0)
    private var buffer = (y: 0.0, x: 0.0)
    private var delta = (y: 0.0, x: 0.0)
    private let filter = ScrollFilter()
    public private(set) var active = false
    public init() {}

    public func add(y: Double, x: Double, configuration: ScrollConfiguration) {
        guard y.isFinite, x.isFinite else { return }
        let y = normalized(y, minimum: configuration.step) * configuration.speed
        let x = normalized(x, minimum: configuration.step) * configuration.speed
        // 反向时同时清掉旧方向滤波尾巴，避免新方向开始后仍向旧方向移动。
        if y != 0 && y * delta.y < 0 { filter.curveWindowY = [0, 0] }
        if x != 0 && x * delta.x < 0 { filter.curveWindowX = [0, 0] }
        if y != 0 {
            if y * delta.y > 0 { buffer.y += y } else { buffer.y = y; current.y = 0 }
            delta.y = y
        }
        if x != 0 {
            if x * delta.x > 0 { buffer.x += x } else { buffer.x = x; current.x = 0 }
            delta.x = x
        }
        active = active || y != 0 || x != 0
    }

    public func next(transition: Double) -> (y: Double, x: Double) {
        guard active else { return (0, 0) }
        let frame = (y: Interpolator.lerp(src: current.y, dest: buffer.y, trans: transition),
                     x: Interpolator.lerp(src: current.x, dest: buffer.x, trans: transition))
        current.y += frame.y
        current.x += frame.x
        let value = filter.fill(with: frame)
        if max(abs(buffer.y - current.y), abs(buffer.x - current.x)) <= 0.1,
           max(abs(value.y), abs(value.x)) <= 0.1 {
            reset()
            return (0, 0)
        }
        return value
    }

    public func reset() {
        current = (0, 0); buffer = (0, 0); delta = (0, 0)
        filter.reset()
        active = false
    }

    private func normalized(_ value: Double, minimum: Double) -> Double {
        value == 0 ? 0 : (value > 0 ? 1 : -1) * max(abs(value), minimum)
    }
}
