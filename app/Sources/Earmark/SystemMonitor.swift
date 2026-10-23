import CoreGraphics
import EarmarkCore
import Foundation
import IOKit
import IOKit.ps

/// Samples what the Mac is doing for the analysis governor. Cheap enough to call
/// every few seconds on the main thread; needs no special permissions.
@MainActor
final class SystemMonitor {
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastOwnCPU: Double?
    private var lastSample: Date?

    func sample() -> SystemSignals {
        let now = Date()
        let ticks = Self.cpuTicks()
        let own = Self.ownCPUSeconds()
        var otherCPU = 0.0
        if let last = lastTicks, let ticks, let lastOwn = lastOwnCPU, let lastTime = lastSample,
           ticks.total > last.total {
            let total = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
            let elapsed = now.timeIntervalSince(lastTime)
            let ours = elapsed > 0 ? (own - lastOwn) / (elapsed * Double(ProcessInfo.processInfo.activeProcessorCount)) : 0
            otherCPU = min(1, max(0, total - ours))
        }
        lastTicks = ticks
        lastOwnCPU = own
        lastSample = now
        let info = ProcessInfo.processInfo
        return SystemSignals(userIdle: Self.userIdleSeconds(), otherCPU: otherCPU, gpu: Self.gpuUtilisation(),
                             thermal: Self.thermal(info.thermalState), onBattery: Self.onBattery(),
                             lowPowerMode: info.isLowPowerModeEnabled)
    }

    /// Seconds since any keyboard, mouse or trackpad event.
    static func userIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Busy and total CPU ticks over all cores since boot.
    static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let user = UInt64(t.0), system = UInt64(t.1), idle = UInt64(t.2), nice = UInt64(t.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// CPU time used by Earmark itself, in seconds.
    static func ownCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Highest "Device Utilization %" reported by the GPU drivers, 0…1.
    static func gpuUtilisation() -> Double {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var highest = 0.0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let percent = stats?["Device Utilization %"] as? NSNumber {
                highest = max(highest, percent.doubleValue / 100)
            }
        }
        return min(1, highest)
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> SystemSignals.Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
