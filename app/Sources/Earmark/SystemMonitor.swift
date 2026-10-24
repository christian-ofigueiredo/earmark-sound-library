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
    private var lastOthersGPU: Double?
    private var lastSample: Date?
    /// Total GPU utilisation at the last sample (0…1), for the log.
    private(set) var totalGPU = 0.0

    /// `ownGPUWork`: Earmark had GPU work (PE-AV) running during the interval.
    func sample(ownGPUWork: Bool) -> SystemSignals {
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
        // The GPU. Without Earmark's own GPU work, total utilisation is other apps'.
        // While PE-AV runs on the GPU, utilisation is mostly Earmark's, and Core ML's GPU
        // time isn't reliably credited to Earmark's process (it often shows under no
        // process, sometimes under a system agent), so other apps' load is the GPU time
        // credited to every other process instead. If some of Earmark's work were credited
        // elsewhere, analysis would only back off more.
        totalGPU = Self.gpuUtilisation()
        let othersTime = Self.othersGPUSeconds()
        var otherGPU = totalGPU
        if ownGPUWork {
            otherGPU = 0
            if let last = lastOthersGPU, let lastTime = lastSample, now > lastTime {
                otherGPU = min(totalGPU, max(0, (othersTime - last) / now.timeIntervalSince(lastTime)))
            }
        }
        lastTicks = ticks
        lastOwnCPU = own
        lastOthersGPU = othersTime
        lastSample = now
        let info = ProcessInfo.processInfo
        return SystemSignals(userIdle: Self.userIdleSeconds(), otherCPU: otherCPU, gpu: otherGPU,
                             thermal: Self.thermal(info.thermalState), onBattery: Self.onBattery(),
                             batteryLevel: Self.batteryLevel(),
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

    /// GPU time used by all other processes, in seconds: the GPU driver's per-client
    /// "accumulatedGPUTime" (nanoseconds) for clients not created by this process.
    static func othersGPUSeconds() -> Double {
        let me = "pid \(ProcessInfo.processInfo.processIdentifier),"
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        var nanoseconds = 0.0
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(children) }
            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                guard let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String, !creator.hasPrefix(me),
                      let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]] else { continue }
                for entry in usage { nanoseconds += (entry["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0 }
            }
        }
        return nanoseconds / 1e9
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    /// Charge of the internal battery, 0…1 (1 if there's none).
    static func batteryLevel() -> Double {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return 1 }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Double, let max = d[kIOPSMaxCapacityKey] as? Double, max > 0
            else { continue }
            return current / max
        }
        return 1
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
