import XCTest
import AppKit
@testable import MosScrollCore

final class ScrollTests: XCTestCase {
    func configuration() -> ScrollConfiguration {
        var value = ScrollConfiguration(); value.enabled = true; return value
    }
    func wheel(y: Int32 = 1, x: Int32 = 0) throws -> CGEvent {
        try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
    }

    func testMosDefaultsAndInvalidConfiguration() {
        var config = configuration()
        XCTAssertEqual(config.transition, 0.085, accuracy: 0.001)
        config.duration = .nan; config.step = .infinity; config.speed = -100
        config.excludedApps = [" com.apple.Safari ", "com.apple.Safari", ""]
        config.normalize()
        XCTAssertEqual(config.duration, 4.35)
        XCTAssertEqual(config.step, 33.6)
        XCTAssertEqual(config.speed, 0.5)
        XCTAssertEqual(config.excludedApps, ["com.apple.Safari"])
    }

    func testSingleNotchConvergesAndStops() {
        let smoother = MosSmoother(), config = configuration()
        smoother.add(y: 1, x: 0, configuration: config)
        var total = 0.0, samples = 0
        while smoother.active && samples < 1000 {
            let frame = smoother.next(transition: config.transition)
            XCTAssertGreaterThanOrEqual(frame.y, 0)
            XCTAssertEqual(frame.x, 0)
            total += frame.y; samples += 1
        }
        XCTAssertFalse(smoother.active)
        XCTAssertGreaterThan(samples, 2)
        XCTAssertEqual(total, config.step * config.speed, accuracy: 1)
        XCTAssertEqual(smoother.next(transition: config.transition).y, 0)
    }

    func testFastReversalDoesNotEmitOldDirection() {
        let smoother = MosSmoother(), config = configuration()
        smoother.add(y: 30, x: 0, configuration: config)
        for _ in 0..<5 { _ = smoother.next(transition: config.transition) }
        smoother.add(y: -30, x: 0, configuration: config)
        for _ in 0..<20 { XCTAssertLessThanOrEqual(smoother.next(transition: config.transition).y, 0) }
    }

    func testHorizontalInputDoesNotEraseVerticalTail() {
        let smoother = MosSmoother(), config = configuration()
        smoother.add(y: 20, x: 0, configuration: config)
        for _ in 0..<3 { _ = smoother.next(transition: config.transition) }
        smoother.add(y: 0, x: 20, configuration: config)
        let frame = smoother.next(transition: config.transition)
        XCTAssertGreaterThan(frame.y, 0)
        _ = smoother.next(transition: config.transition)
        XCTAssertGreaterThan(smoother.next(transition: config.transition).x, 0)
    }

    func testResetDropsAllPendingOutput() {
        let smoother = MosSmoother(), config = configuration()
        smoother.add(y: 100, x: 100, configuration: config)
        smoother.reset()
        XCTAssertFalse(smoother.active)
        XCTAssertEqual(smoother.next(transition: config.transition).y, 0)
        XCTAssertEqual(smoother.next(transition: config.transition).x, 0)
    }

    func testContinuousGestureAndMarkedEventsPassThrough() throws {
        let event = try wheel()
        XCTAssertTrue(ScrollEventAdapter.isDiscreteWheel(event))
        for field in [CGEventField.scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase,
                      .scrollWheelEventMomentumPhase, .scrollWheelEventScrollCount] {
            event.setIntegerValueField(field, value: 1)
            XCTAssertFalse(ScrollEventAdapter.isDiscreteWheel(event))
            event.setIntegerValueField(field, value: 0)
        }
        event.setIntegerValueField(.eventSourceUserData, value: ScrollEventAdapter.marker)
        XCTAssertFalse(ScrollEventAdapter.isDiscreteWheel(event))
    }

    func testReverseBothAxesAllRepresentations() throws {
        let event = try wheel(y: 2, x: -3)
        let beforeY = ScrollEventAdapter.value(event, horizontal: false)
        let beforeX = ScrollEventAdapter.value(event, horizontal: true)
        ScrollEventAdapter.reverse(event, horizontal: false)
        XCTAssertEqual(ScrollEventAdapter.value(event, horizontal: false), -beforeY)
        XCTAssertEqual(ScrollEventAdapter.value(event, horizontal: true), beforeX)
        ScrollEventAdapter.reverse(event, horizontal: true)
        XCTAssertEqual(ScrollEventAdapter.value(event, horizontal: true), -beforeX)
    }

    func testSyntheticFramePreservesTargetAndCannotReenter() throws {
        let event = try wheel(y: 2, x: 3)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 1234)
        event.location = CGPoint(x: 200, y: 300)
        let frame = try XCTUnwrap(ScrollEventAdapter.frame(from: event, y: 2, x: -3))
        XCTAssertEqual(frame.getIntegerValueField(.eventTargetUnixProcessID), 1234)
        XCTAssertEqual(frame.location, event.location)
        XCTAssertEqual(ScrollEventAdapter.value(frame, horizontal: false), 2)
        XCTAssertEqual(ScrollEventAdapter.value(frame, horizontal: true), -3)
        XCTAssertFalse(ScrollEventAdapter.isDiscreteWheel(frame))
        XCTAssertFalse(ScrollEventAdapter.isSynthetic(event))
    }

    func testDisabledEngineDoesNotInstallTap() {
        XCTAssertTrue(Thread.isMainThread)
        let engine = ScrollEngine()
        engine.update(ScrollConfiguration())
        XCTAssertFalse(engine.start())
        XCTAssertFalse(engine.running)
        engine.stop(); engine.stop()
    }

    func testTapDoesNotWakeOnMouseMove() {
        // 与 Mos 一致：不监听鼠标移动，挪鼠标既不唤醒组件，也不丢掉剩余滚动距离。
        XCTAssertEqual(ScrollEngine.eventMask & (1 << CGEventType.mouseMoved.rawValue), 0)
        XCTAssertNotEqual(ScrollEngine.eventMask & (1 << CGEventType.scrollWheel.rawValue), 0)
    }

    func testTapRestartBudgetAllowsOccasionalTimeoutsOnly() {
        var budget = TapRestartBudget()
        XCTAssertTrue(budget.allow(at: 0))
        XCTAssertTrue(budget.allow(at: 1))
        XCTAssertTrue(budget.allow(at: 2))
        // 10 秒内第 4 次说明回调本身出了问题，停下交还原生滚动，不无限重启。
        XCTAssertFalse(budget.allow(at: 3))
        XCTAssertTrue(budget.allow(at: 20))
    }

    func testDecodesConfigWrittenByFriday() throws {
        // 与星期五 MouseSettings 的字段一一对应；改字段名两边要一起改（星期五那边也有同样的测试）。
        let json = #"{"enabled":true,"smoothVertical":true,"smoothHorizontal":false,"reverseVertical":true,"reverseHorizontal":false,"step":33.6,"speed":2.7,"duration":4.35,"excludedApps":["com.apple.Safari"]}"#
        let config = try XCTUnwrap(SharedStore.decodeConfiguration(Data(json.utf8)))
        XCTAssertTrue(config.enabled)
        XCTAssertTrue(config.reverseVertical)
        XCTAssertFalse(config.smoothHorizontal)
        XCTAssertEqual(config.excludedApps, ["com.apple.Safari"])
        XCTAssertNil(SharedStore.decodeConfiguration(Data("{}".utf8)))
    }

    func testCtrlAndCommandScrollKeepReversedDirectionButSkipSmoothing() throws {
        // 用户开了反转：按住 Ctrl/Command 缩放时方向也要反转，否则「Ctrl+上滚放大」会变成缩小（与 Mos 一致）。
        var config = configuration(); config.reverseVertical = true
        for flag in [CGEventFlags.maskControl, .maskCommand] {
            let event = try wheel(y: 2)
            let before = ScrollEventAdapter.value(event, horizontal: false)
            event.flags = flag
            XCTAssertFalse(ScrollEngine.applyDirection(event, configuration: config))
            XCTAssertEqual(ScrollEventAdapter.value(event, horizontal: false), -before)
        }
        let plain = try wheel(y: 2)
        XCTAssertTrue(ScrollEngine.applyDirection(plain, configuration: config))
    }

    func testFractionalFramesRetainDistanceAndReversePromptly() {
        var pixels = PixelAccumulator()
        let total = (0..<100).reduce(0.0) { sum, _ in sum + pixels.take(0.25) }
        XCTAssertEqual(total, 25)
        _ = pixels.take(0.75)
        XCTAssertEqual(pixels.take(-1), -1)
    }
}
