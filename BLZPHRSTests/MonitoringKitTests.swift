import MonitoringKit
import XCTest

final class MonitoringKitTests: XCTestCase {
    func testFanCurveFloorUntil55() {
        XCTAssertEqual(FanCurve.percent(celsius: 50, floor: 40), 40, accuracy: 0.01)
        XCTAssertEqual(FanCurve.percent(celsius: 55, floor: 40), 40, accuracy: 0.01)
    }

    func testFanCurveClimbsThenCaps() {
        XCTAssertEqual(FanCurve.percent(celsius: 70, floor: 40), 70, accuracy: 0.01)
        XCTAssertEqual(FanCurve.percent(celsius: 85, floor: 40), 100, accuracy: 0.01)
        XCTAssertEqual(FanCurve.percent(celsius: 95, floor: 40), 100, accuracy: 0.01)
    }

    func testFanCurveSmoothing() {
        XCTAssertEqual(FanCurve.smoothed(current: 80, target: 40, maxDrop: 8), 72, accuracy: 0.01)
        XCTAssertEqual(FanCurve.smoothed(current: 40, target: 80, maxDrop: 8), 80, accuracy: 0.01)
    }

    func testFanRPMStaysInsideLimits() {
        XCTAssertEqual(FanCurve.rpm(percent: 0, minimum: 2317, maximum: 7826), 2317, accuracy: 0.01)
        XCTAssertEqual(FanCurve.rpm(percent: 100, minimum: 2317, maximum: 7826), 7826, accuracy: 0.01)
        XCTAssertEqual(FanCurve.rpm(percent: 150, minimum: 2317, maximum: 7826), 7826, accuracy: 0.01)
    }

    func testSMCFloatDecode() {
        let bytes: [UInt8] = [0x00, 0xD0, 0x10, 0x45]
        var ok: Int32 = 0
        let value = bytes.withUnsafeBufferPointer { buffer in
            SMCDecodeValue("flt ", buffer.baseAddress, 4, &ok)
        }
        XCTAssertEqual(ok, 1)
        XCTAssertEqual(value, 2317, accuracy: 1)
    }

    func testHealthScore() {
        let excellent = SystemHealth.score(pressureLevel: 1, thermalState: 0, cpuCelsius: 50)
        XCTAssertEqual(excellent.value, 100)
        XCTAssertEqual(excellent.title, "Excellent")
        let poor = SystemHealth.score(pressureLevel: 4, thermalState: 3, cpuCelsius: 96)
        XCTAssertEqual(poor.value, 25)
        XCTAssertEqual(poor.title, "Poor")
    }

    func testChargeEstimate() {
        let seconds = ChargeEstimate.seconds(toLimit: 0.8, fullChargeMah: 6065, remainingMah: 4792, amperageMa: 3862)
        XCTAssertEqual(seconds ?? 0, 55.9, accuracy: 0.2)
    }

    func testCounterDelta() {
        XCTAssertEqual(CounterDelta.perSecond(previous: 1000, current: 3000, elapsed: 2), 1000, accuracy: 0.01)
        XCTAssertEqual(CounterDelta.perSecond(previous: 3000, current: 1000, elapsed: 2), 0, accuracy: 0.01)
    }

    func testSensorMapForThisMac() {
        XCTAssertEqual(SensorMap.classify(key: "Tm0P", modelIdentifier: "Mac17,7"), .cpu)
        XCTAssertEqual(SensorMap.classify(key: "Tg0D", modelIdentifier: "Mac17,7"), .gpu)
        XCTAssertNil(SensorMap.classify(key: "Tp0P", modelIdentifier: "Mac17,7"))
        let selected = SensorMap.select(keys: [("Tm0P", "flt "), ("Tg0D", "flt "), ("Tp0P", "flt ")], modelIdentifier: "Mac17,7")
        XCTAssertEqual(selected.cpu, ["Tm0P"])
        XCTAssertEqual(selected.gpu, ["Tg0D"])
    }

    func testCPUTimeUsesMachTicks() {
        XCTAssertEqual(CPUTime.percent(deltaTicks: 100, deltaWallTicks: 100), 100, accuracy: 0.01)
        XCTAssertEqual(CPUTime.percent(deltaTicks: 50, deltaWallTicks: 100), 50, accuracy: 0.01)
    }
}
