import Darwin
import Foundation
import MonitoringKit

final class ThermalSampler: @unchecked Sendable {
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var discovered = false
    private var fans: [FanLimits] = []
    private var history = MetricHistory()
    private var discovery = SampleDeadline()
    func reset() { history = MetricHistory(); discovered = false; discovery = SampleDeadline() }

    struct FanLimits {
        var index: Int
        var minimum: Double
        var maximum: Double
        var modeKey: String
    }

    func temperatures() -> (cpu: Double?, gpu: Double?, peak: Double?, hottest: Double?) {
        discoverIfNeeded()
        let cpuValues = cpuKeys.compactMap { SMCAccess.readFloat($0) }
        let gpuValues = gpuKeys.compactMap { SMCAccess.readFloat($0) }
        let cpu = SensorMap.averageCelsius(cpuValues)
        let gpu = SensorMap.averageCelsius(gpuValues)
        let now = SampleClock.now
        history.append(cpu, at: now)
        return (cpu, gpu, history.maximum(at: now), cpuValues.filter { $0.isFinite && $0 > 5 && $0 < 130 }.max())
    }

    func fansNow() -> [FanReading] {
        discoverIfNeeded()
        return fans.compactMap { fan in
            guard let rpm = SMCAccess.readFloat("F\(fan.index)Ac"), rpm.isFinite, rpm >= 0 else { return nil }
            let manual = (SMCAccess.readUI8(fan.modeKey) ?? 0) != 0
            return FanReading(index: fan.index, rpm: rpm, minimum: fan.minimum, maximum: fan.maximum, manual: manual)
        }
    }

    private func discoverIfNeeded() {
        guard !discovered, discovery.due(at: SampleClock.now, interval: 30) else { return }
        fans = []
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        if sysctlbyname("hw.model", &model, &size, nil, 0) != 0 { model[0] = 0 }
        let identifier = String(cString: model)
        let selected = SensorMap.select(keys: SMCAccess.keys(), modelIdentifier: identifier)
        cpuKeys = selected.cpu
        gpuKeys = selected.gpu
        discovered = !cpuKeys.isEmpty || !gpuKeys.isEmpty
        let count = min(Int(SMCAccess.readUI8("FNum") ?? 0), 8)
        for index in 0..<count {
            guard let minimum = SMCAccess.readFloat("F\(index)Mn"),
                  let maximum = SMCAccess.readFloat("F\(index)Mx"),
                  maximum > minimum else { continue }
            let lower = "F\(index)md"
            let upper = "F\(index)Md"
            let modeKey = SMCAccess.readUI8(lower) != nil ? lower : upper
            fans.append(FanLimits(index: index, minimum: minimum, maximum: maximum, modeKey: modeKey))
        }
    }
}
