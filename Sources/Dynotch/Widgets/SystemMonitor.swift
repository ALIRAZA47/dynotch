import Darwin
import Foundation

/// CPU, memory, disk and network, sampled only while someone is looking.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: UInt64 = 0
    let memoryTotal = ProcessInfo.processInfo.physicalMemory
    @Published private(set) var diskFree: Int64 = 0
    @Published private(set) var diskTotal: Int64 = 0
    @Published private(set) var download: Double = 0
    @Published private(set) var upload: Double = 0

    private var viewers = 0
    private var poll: Poll?
    private var previousTicks: [UInt32] = []
    private var previousNetwork: (received: UInt64, sent: UInt64, date: Date)?

    private init() {}

    var memoryFraction: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0 }
    var diskUsedFraction: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) : 0 }

    func beginObserving() {
        viewers += 1
        guard poll == nil else { return }
        // CPU load is a difference between two readings: take one now and another shortly after.
        sample()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if poll != nil { sample() }
        }
        poll = EnergyCoordinator.shared.schedule(.systemStats) { [weak self] in self?.sample() }
    }

    func endObserving() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        poll?.cancel()
        poll = nil
        previousNetwork = nil
    }

    private func sample() {
        if let load = sampleCPU() {
            cpu = load
            cpuHistory = Array((cpuHistory + [load]).suffix(30))
        }
        memoryUsed = sampleMemory()
        sampleDisk()
        sampleNetwork()
    }

    /// nil until there's an earlier reading to compare with.
    private func sampleCPU() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [UInt32] = []
        for core in 0..<Int(cpuCount) {
            let base = core * Int(CPU_STATE_MAX)
            ticks.append(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            ticks.append(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            ticks.append(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            ticks.append(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for index in stride(from: 0, to: ticks.count, by: 4) {
            let user = UInt64(ticks[index] &- previousTicks[index])
            let system = UInt64(ticks[index + 1] &- previousTicks[index + 1])
            let nice = UInt64(ticks[index + 2] &- previousTicks[index + 2])
            let idle = UInt64(ticks[index + 3] &- previousTicks[index + 3])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return total > 0 ? Double(busy) / Double(total) : 0
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func sampleMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return memoryUsed }
        let pageSize = UInt64(getpagesize())
        let appPages = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    private func sampleDisk() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return }
        diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
        diskTotal = Int64(values.volumeTotalCapacity ?? 0)
    }

    private func sampleNetwork() {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: interface.ifa_name).hasPrefix("en"),
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }
        let now = Date.now
        if let previous = previousNetwork, received >= previous.received, sent >= previous.sent {
            let seconds = max(0.1, now.timeIntervalSince(previous.date))
            download = Double(received - previous.received) / seconds
            upload = Double(sent - previous.sent) / seconds
        }
        previousNetwork = (received, sent, now)
    }

    // MARK: Snapshots

    func loadSample() {
        cpu = 0.23
        cpuHistory = (0..<30).map { 0.15 + 0.12 * abs(sin(Double($0) / 3)) }
        memoryUsed = UInt64(Double(memoryTotal) * 0.58)
        diskTotal = 994_662_584_320
        diskFree = 412_000_000_000
        download = 1_240_000
        upload = 86_000
    }
}
