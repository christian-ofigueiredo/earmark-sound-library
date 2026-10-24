import Foundation

/// What the Mac is doing, sampled every few seconds by the app.
public struct SystemSignals: Sendable, Equatable {
    public enum Thermal: Int, Sendable, Comparable {
        case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue }
    }

    /// Seconds since the last keyboard, mouse or trackpad input.
    public var userIdle: TimeInterval
    /// CPU used by other apps, 0…1 of all cores (Earmark's own use is excluded).
    public var otherCPU: Double
    /// Other apps' GPU utilisation, 0…1: the total minus Earmark's own share (it uses
    /// the GPU for PE-AV while the Mac is idle). A Resolve export shows up here first.
    public var gpu: Double
    public var thermal: Thermal
    public var onBattery: Bool
    public var lowPowerMode: Bool

    public init(userIdle: TimeInterval, otherCPU: Double, gpu: Double, thermal: Thermal = .nominal,
                onBattery: Bool = false, lowPowerMode: Bool = false) {
        self.userIdle = userIdle; self.otherCPU = otherCPU; self.gpu = gpu
        self.thermal = thermal; self.onBattery = onBattery; self.lowPowerMode = lowPowerMode
    }
}

/// How hard analysis may work right now, and why (shown in the status bar).
public struct AnalysisPace: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case pausedByUser, waitingForIdle, macBusy, hot, battery, lowPower
        case userActive   // gentle: you're using the Mac
        case idle         // full speed
        case requested    // full speed because the user asked
    }

    public var workers: Int
    public var reason: Reason

    public var isPaused: Bool { workers == 0 }

    public init(workers: Int, reason: Reason) { self.workers = workers; self.reason = reason }
}

/// Decides how many analysis workers may run. Analysis runs mainly while the
/// Mac is idle (e.g. overnight), backs off at once when the Mac gets busy, and
/// only speeds up again after conditions have held for a while, so a short
/// pause in an export doesn't start heavy work.
public struct AnalysisGovernor: Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        /// Full speed when idle, one gentle worker while you work.
        case automatic
        /// Nothing at all while you use the Mac.
        case idleOnly
        /// The user asked for it: full speed even while the Mac is in use (heat,
        /// battery and Low Power Mode still stop it). Not remembered across launches.
        case fullSpeed
        case paused
    }

    public struct Settings: Sendable, Equatable {
        /// No input for this long counts as idle.
        public var idleAfter: TimeInterval = 300
        /// While you use the Mac, other apps using more than this (CPU or GPU) pause
        /// analysis, e.g. editing in Resolve. Below the quiet level it may work again.
        public var busyCPU = 0.5, busyGPU = 0.35
        public var quietCPU = 0.25, quietGPU = 0.15
        /// Once the Mac is idle, apps left open (Resolve keeps its viewer on the GPU)
        /// shouldn't block the night's work; only heavy load, like an export, does.
        public var idleBusyCPU = 0.6, idleBusyGPU = 0.6
        public var idleQuietCPU = 0.4, idleQuietGPU = 0.45
        /// How long conditions must allow more work before workers are added.
        public var rampUpAfter: TimeInterval = 60
        public var fullWorkers: Int

        public init(fullWorkers: Int) { self.fullWorkers = max(1, fullWorkers) }
    }

    /// Changing the mode is the user's choice, so the next update applies it without ramp-up.
    public var mode: Mode { didSet { modeChanged = mode != oldValue } }
    public var settings: Settings
    private var modeChanged = false
    public private(set) var pace = AnalysisPace(workers: 0, reason: .waitingForIdle)
    /// Since when the conditions have allowed more workers than are running.
    private var allowedSince: Date?

    public init(mode: Mode = .automatic, settings: Settings) {
        self.mode = mode
        self.settings = settings
    }

    /// Updates and returns the pace for the latest signals.
    @discardableResult
    public mutating func update(_ s: SystemSignals, now: Date = Date()) -> AnalysisPace {
        let target = self.target(for: s)
        // Slowing down applies at once, and so does any change the user makes.
        // Speeding up otherwise waits until conditions have held for rampUpAfter.
        defer { modeChanged = false }
        if target.workers <= pace.workers || modeChanged {
            pace = target
            allowedSince = nil
        } else if let since = allowedSince {
            if now.timeIntervalSince(since) >= settings.rampUpAfter {
                pace = target
                allowedSince = nil
            }
        } else {
            allowedSince = now
        }
        return pace
    }

    /// The pace the signals allow, ignoring ramp-up.
    func target(for s: SystemSignals) -> AnalysisPace {
        if mode == .paused { return AnalysisPace(workers: 0, reason: .pausedByUser) }
        if s.thermal >= .serious { return AnalysisPace(workers: 0, reason: .hot) }
        if s.lowPowerMode { return AnalysisPace(workers: 0, reason: .lowPower) }
        if s.onBattery { return AnalysisPace(workers: 0, reason: .battery) }
        if mode == .fullSpeed { return AnalysisPace(workers: settings.fullWorkers, reason: .requested) }
        // Busy above the high threshold; once paused for being busy, stay paused
        // until load drops below the low one.
        let idle = s.userIdle >= settings.idleAfter
        let wasBusy = pace.reason == .macBusy
        let cpuLimit = idle ? (wasBusy ? settings.idleQuietCPU : settings.idleBusyCPU) : (wasBusy ? settings.quietCPU : settings.busyCPU)
        let gpuLimit = idle ? (wasBusy ? settings.idleQuietGPU : settings.idleBusyGPU) : (wasBusy ? settings.quietGPU : settings.busyGPU)
        if s.otherCPU > cpuLimit || s.gpu > gpuLimit { return AnalysisPace(workers: 0, reason: .macBusy) }
        if idle {
            let workers = s.thermal == .fair ? max(1, settings.fullWorkers / 2) : settings.fullWorkers
            return AnalysisPace(workers: workers, reason: .idle)
        }
        if mode == .idleOnly { return AnalysisPace(workers: 0, reason: .waitingForIdle) }
        return AnalysisPace(workers: 1, reason: .userActive)
    }
}
