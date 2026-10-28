import Foundation

enum FocusMode: String, Codable, CaseIterable {
    case countdown
    case pomodoro
}

enum FocusPhase: String, Codable, CaseIterable {
    case work
    case shortBreak
    case longBreak
}

enum FocusStatus: String, Codable, CaseIterable {
    case idle
    case running
    case paused
    case completed
}

struct FocusSettings: Codable, Equatable {
    static let standard = FocusSettings()

    var workMinutes: Int
    var shortBreakMinutes: Int
    var longBreakMinutes: Int
    var longBreakInterval: Int

    init(workMinutes: Int = 25, shortBreakMinutes: Int = 5, longBreakMinutes: Int = 15, longBreakInterval: Int = 4) {
        self.workMinutes = Self.clamp(workMinutes, to: 1...180)
        self.shortBreakMinutes = Self.clamp(shortBreakMinutes, to: 1...180)
        self.longBreakMinutes = Self.clamp(longBreakMinutes, to: 1...180)
        self.longBreakInterval = Self.clamp(longBreakInterval, to: 1...12)
    }

    var sanitized: FocusSettings {
        FocusSettings(
            workMinutes: workMinutes,
            shortBreakMinutes: shortBreakMinutes,
            longBreakMinutes: longBreakMinutes,
            longBreakInterval: longBreakInterval
        )
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case workMinutes
        case shortBreakMinutes
        case longBreakMinutes
        case longBreakInterval
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workMinutes: try values.decodeIfPresent(Int.self, forKey: .workMinutes) ?? 25,
            shortBreakMinutes: try values.decodeIfPresent(Int.self, forKey: .shortBreakMinutes) ?? 5,
            longBreakMinutes: try values.decodeIfPresent(Int.self, forKey: .longBreakMinutes) ?? 15,
            longBreakInterval: try values.decodeIfPresent(Int.self, forKey: .longBreakInterval) ?? 4
        )
    }
}

struct FocusTask: Codable, Equatable {
    var title: String
    var reminderID: String?
    var listName: String?
}

struct FocusSession: Codable, Equatable {
    private(set) var mode: FocusMode
    private(set) var phase: FocusPhase
    private(set) var status: FocusStatus
    private(set) var settings: FocusSettings
    private(set) var task: FocusTask?
    private(set) var completedWorkSessions: Int
    private(set) var durationSeconds: TimeInterval
    private var checkpointSeconds: TimeInterval
    private(set) var anchorDate: Date?

    init(settings: FocusSettings = .standard) {
        mode = .countdown
        phase = .work
        status = .idle
        self.settings = settings.sanitized
        task = nil
        completedWorkSessions = 0
        durationSeconds = 0
        checkpointSeconds = 0
        anchorDate = nil
    }

    var nextPhase: FocusPhase? {
        guard mode == .pomodoro, status == .completed else { return nil }
        if phase == .work {
            return completedWorkSessions.isMultiple(of: settings.longBreakInterval) ? .longBreak : .shortBreak
        }
        return .work
    }

    static func start(
        mode: FocusMode,
        minutes: Int,
        settings: FocusSettings = .standard,
        task: FocusTask? = nil,
        at date: Date = Date()
    ) -> FocusSession {
        let minutes = min(max(minutes, 1), 180)
        var settings = settings.sanitized
        if mode == .pomodoro { settings.workMinutes = minutes }
        let duration = TimeInterval(minutes * 60)
        return FocusSession(
            mode: mode,
            phase: .work,
            status: .running,
            settings: settings,
            task: task,
            completedWorkSessions: 0,
            durationSeconds: duration,
            checkpointSeconds: duration,
            anchorDate: date
        )
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        guard status == .running, let anchorDate else { return checkpointSeconds }
        return max(0, checkpointSeconds - max(0, date.timeIntervalSince(anchorDate)))
    }

    mutating func tick(at date: Date = Date()) {
        guard status == .running, remaining(at: date) <= 0 else { return }
        completePhase()
    }

    mutating func pause(at date: Date = Date()) {
        guard status == .running else { return }
        let remaining = remaining(at: date)
        guard remaining > 0 else {
            completePhase()
            return
        }
        checkpointSeconds = remaining
        anchorDate = nil
        status = .paused
    }

    mutating func resume(at date: Date = Date()) {
        guard status == .paused, checkpointSeconds > 0 else { return }
        anchorDate = date
        status = .running
    }

    mutating func setRemaining(minutes: Int) {
        guard status == .paused else { return }
        let elapsed = durationSeconds - checkpointSeconds
        let requestedSeconds = TimeInterval(min(max(minutes, 1), 180) * 60)
        let maximumRemaining = max(0, 180 * 60 - elapsed)
        let remaining = min(requestedSeconds, maximumRemaining)
        durationSeconds = elapsed + remaining
        checkpointSeconds = remaining
        anchorDate = nil
    }

    mutating func addFiveMinutes(at date: Date = Date()) {
        guard status == .running else { return }
        let currentRemaining = remaining(at: date)
        guard currentRemaining > 0 else {
            completePhase()
            return
        }
        let extensionSeconds = min(5 * 60, max(0, 180 * 60 - durationSeconds))
        durationSeconds += extensionSeconds
        checkpointSeconds = currentRemaining + extensionSeconds
        anchorDate = date
    }

    mutating func advancePhase(at date: Date = Date()) {
        guard let nextPhase else { return }
        phase = nextPhase
        let minutes: Int
        switch nextPhase {
        case .work: minutes = settings.workMinutes
        case .shortBreak: minutes = settings.shortBreakMinutes
        case .longBreak: minutes = settings.longBreakMinutes
        }
        durationSeconds = TimeInterval(minutes * 60)
        checkpointSeconds = durationSeconds
        anchorDate = date
        status = .running
    }

    mutating func detachReminder(at date: Date = Date()) {
        guard task?.reminderID != nil else { return }
        checkpoint(at: date)
        task?.reminderID = nil
    }

    mutating func checkpoint(at date: Date) {
        guard status == .running else { return }
        let remaining = remaining(at: date)
        guard remaining > 0 else {
            completePhase()
            return
        }
        checkpointSeconds = remaining
        anchorDate = date
    }

    mutating func end() {
        phase = .work
        status = .idle
        mode = .countdown
        task = nil
        completedWorkSessions = 0
        durationSeconds = 0
        checkpointSeconds = 0
        anchorDate = nil
    }

    private mutating func completePhase() {
        guard status == .running else { return }
        checkpointSeconds = 0
        anchorDate = nil
        status = .completed
        if phase == .work, completedWorkSessions < Int.max {
            completedWorkSessions += 1
        }
    }

    private init(
        mode: FocusMode,
        phase: FocusPhase,
        status: FocusStatus,
        settings: FocusSettings,
        task: FocusTask?,
        completedWorkSessions: Int,
        durationSeconds: TimeInterval,
        checkpointSeconds: TimeInterval,
        anchorDate: Date?
    ) {
        self.mode = mode
        self.phase = phase
        self.status = status
        self.settings = settings.sanitized
        self.task = task
        self.completedWorkSessions = max(0, completedWorkSessions)
        self.durationSeconds = Self.validDuration(durationSeconds)
        self.checkpointSeconds = min(max(0, checkpointSeconds), self.durationSeconds)
        self.anchorDate = anchorDate
    }

    private static func validDuration(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite ? min(max(0, duration), 180 * 60) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case phase
        case status
        case settings
        case task
        case completedWorkSessions
        case durationSeconds
        case checkpointSeconds
        case anchorDate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedStatus = try values.decodeIfPresent(FocusStatus.self, forKey: .status) ?? .idle
        let duration = try values.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds) ?? 0
        let checkpoint = try values.decodeIfPresent(TimeInterval.self, forKey: .checkpointSeconds) ?? 0
        let settings = try values.decodeIfPresent(FocusSettings.self, forKey: .settings) ?? .standard
        let safeDuration = Self.validDuration(duration)

        self.init(
            mode: try values.decodeIfPresent(FocusMode.self, forKey: .mode) ?? .countdown,
            phase: try values.decodeIfPresent(FocusPhase.self, forKey: .phase) ?? .work,
            status: savedStatus == .running ? .paused : savedStatus,
            settings: settings,
            task: try values.decodeIfPresent(FocusTask.self, forKey: .task),
            completedWorkSessions: try values.decodeIfPresent(Int.self, forKey: .completedWorkSessions) ?? 0,
            durationSeconds: safeDuration,
            checkpointSeconds: savedStatus == .completed ? 0 : checkpoint,
            anchorDate: savedStatus == .running ? nil : try values.decodeIfPresent(Date.self, forKey: .anchorDate)
        )

        if duration <= 0 || !duration.isFinite {
            status = .idle
            phase = .work
            mode = .countdown
            task = nil
            completedWorkSessions = 0
            checkpointSeconds = 0
            anchorDate = nil
        } else if mode == .countdown, phase != .work {
            phase = .work
        }
    }
}
