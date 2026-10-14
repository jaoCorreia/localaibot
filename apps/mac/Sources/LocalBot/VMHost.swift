import Foundation
import Virtualization

/// A VM bundle created by Lume (~/.lume/<name>): config.json + disk.img + nvram.bin.
/// Lume creates and provisions it; this app boots it in-process so the screen
/// can be shown natively with VZVirtualMachineView.
struct VMBundle: Identifiable, Hashable {
    let name: String
    let url: URL
    var id: String { name }

    struct Config: Decodable {
        let os: String
        let cpuCount: Int
        let memorySize: UInt64
        let display: String
        let macAddress: String?
        let hardwareModel: Data?      // base64 in JSON
        let machineIdentifier: Data?  // base64 in JSON
    }

    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var nvramURL: URL { url.appendingPathComponent("nvram.bin") }

    var isReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: configURL.path)
            && fm.fileExists(atPath: diskURL.path)
            && fm.fileExists(atPath: nvramURL.path)
            && !fm.fileExists(atPath: url.appendingPathComponent(".provisioning").path)
    }

    func loadConfig() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: configURL))
    }

    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lume")

    static func discover() -> [VMBundle] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.sorted().compactMap { name in
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else { return nil }
            return VMBundle(name: name, url: url)
        }
    }
}

enum VMError: LocalizedError {
    case notReady, unsupported(String), invalid(String)
    var errorDescription: String? {
        switch self {
        case .notReady: return "Lume is still creating this VM."
        case .unsupported(let s): return "Unsupported: \(s)"
        case .invalid(let s): return "Invalid configuration: \(s)"
        }
    }
}

@MainActor
final class VMHost: NSObject, ObservableObject, VZVirtualMachineDelegate {
    enum State: Equatable {
        case stopped, starting, running, stopping
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Off"
            case .starting: return "Starting…"
            case .running: return "On"
            case .stopping: return "Shutting down…"
            case .failed(let msg): return "Error: \(msg)"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var machine: VZVirtualMachine?
    let bundle: VMBundle

    init(bundle: VMBundle) {
        self.bundle = bundle
    }

    func start() {
        guard state == .stopped || isFailed else { return }
        state = .starting
        do {
            guard bundle.isReady else { throw VMError.notReady }
            let configuration = try makeConfiguration()
            let vm = VZVirtualMachine(configuration: configuration)
            vm.delegate = self
            machine = vm
            vm.start { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success: self?.state = .running
                    case .failure(let error): self?.fail(error)
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    /// Asks the guest to shut down; forces it off if it does not within 20s.
    func stop() {
        guard let vm = machine, state == .running else { return }
        state = .stopping
        if vm.canRequestStop {
            try? vm.requestStop()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.state == .stopping, let vm = self.machine, vm.canStop else { return }
            vm.stop { _ in Task { @MainActor in self.didStop() } }
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func fail(_ error: Error) {
        machine = nil
        state = .failed(error.localizedDescription)
    }

    private func didStop() {
        machine = nil
        state = .stopped
    }

    // MARK: VZVirtualMachineDelegate

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in self.didStop() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }

    // MARK: Configuration (mirrors Lume's DarwinVM setup)

    private func makeConfiguration() throws -> VZVirtualMachineConfiguration {
        let config = try bundle.loadConfig()
        guard config.os.lowercased() == "macos" else { throw VMError.unsupported("VM \(config.os)") }
        guard let hw = config.hardwareModel, let model = VZMacHardwareModel(dataRepresentation: hw),
              model.isSupported else { throw VMError.invalid("hardwareModel") }
        guard let mid = config.machineIdentifier,
              let machineID = VZMacMachineIdentifier(dataRepresentation: mid) else {
            throw VMError.invalid("machineIdentifier")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.nvramURL)

        let vz = VZVirtualMachineConfiguration()
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
        vz.cpuCount = config.cpuCount
        vz.memorySize = config.memorySize

        let size = config.display.split(separator: "x").compactMap { Int($0) }
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: size.first ?? 1440,
            heightInPixels: size.count > 1 ? size[1] : 900,
            pixelsPerInch: 80
        )]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        vz.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let mac = config.macAddress.flatMap(VZMACAddress.init(string:)) {
            network.macAddress = mac
        }
        vz.networkDevices = [network]

        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Shared clipboard between host and guest.
        let console = VZVirtioConsoleDeviceConfiguration()
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = true
        port.attachment = spice
        console.ports[0] = port
        vz.consoleDevices = [console]

        try vz.validate()
        return vz
    }
}
