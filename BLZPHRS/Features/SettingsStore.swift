import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var slot1: MenuMetric { didSet { save() } }
    @Published var slot2: MenuMetric { didSet { save() } }
    @Published var slot3: MenuMetric { didSet { save() } }
    @Published var coolFloor: Int { didSet { save() } }
    @Published var autoReturnWhenCool: Bool { didSet { save() } }
    @Published var chargeLimit: Bool { didSet { save() } }
    @Published var allowClosedLid: Bool { didSet { save() } }

    var showsTemperature: Bool { [slot1, slot2, slot3].contains(.temperature) }
    var showsFan: Bool { [slot1, slot2, slot3].contains(.fan) }
    var showsDisk: Bool { [slot1, slot2, slot3].contains(.disk) }
    var showsBattery: Bool { [slot1, slot2, slot3].contains(.battery) }

    private var loading = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loading = true
        slot1 = MenuMetric(rawValue: defaults.string(forKey: "slot1") ?? "") ?? .memory
        slot2 = MenuMetric(rawValue: defaults.string(forKey: "slot2") ?? "") ?? .swap
        slot3 = MenuMetric(rawValue: defaults.string(forKey: "slot3") ?? "") ?? .disk
        coolFloor = defaults.object(forKey: "coolFloor") as? Int ?? 40
        autoReturnWhenCool = defaults.bool(forKey: "autoReturnWhenCool")
        chargeLimit = defaults.bool(forKey: "chargeLimit")
        allowClosedLid = defaults.bool(forKey: "allowClosedLid")
        loading = false
    }

    private func save() {
        guard !loading else { return }
        defaults.set(slot1.rawValue, forKey: "slot1")
        defaults.set(slot2.rawValue, forKey: "slot2")
        defaults.set(slot3.rawValue, forKey: "slot3")
        defaults.set(coolFloor, forKey: "coolFloor")
        defaults.set(autoReturnWhenCool, forKey: "autoReturnWhenCool")
        defaults.set(chargeLimit, forKey: "chargeLimit")
        defaults.set(allowClosedLid, forKey: "allowClosedLid")
    }
}
