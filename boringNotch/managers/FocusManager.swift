import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class FocusManager: ObservableObject {
    static let shared = FocusManager()

    @Published private(set) var session: FocusSession
    @Published private(set) var remainingSeconds: Int
    @Published var settings: FocusSettings {
        didSet {
            let sanitized = settings.sanitized
            if sanitized != settings { settings = sanitized }
            persistSettings()
        }
    }
    @Published private(set) var completionNoticeVisible = false

    private var timerTask: Task<Void, Never>?
    private var completionNoticeTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?

    private init() {
        let storedSettings = Defaults[.focusSettings].flatMap { try? JSONDecoder().decode(FocusSettings.self, from: $0) } ?? .standard
        let restoredSession = Defaults[.focusSession].flatMap { try? JSONDecoder().decode(FocusSession.self, from: $0) }
        let initialSettings = storedSettings.sanitized
        let initialSession = restoredSession ?? FocusSession(settings: initialSettings)

        settings = initialSettings
        session = initialSession
        remainingSeconds = Self.displaySeconds(initialSession.remaining())
        observeSleep()
    }

    deinit {
        timerTask?.cancel()
        completionNoticeTask?.cancel()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

    func start(mode: FocusMode, minutes: Int, task: FocusTask? = nil) {
        cancelCompletionNotice()
        let now = Date()
        session = FocusSession.start(mode: mode, minutes: minutes, settings: settings, task: task, at: now)
        remainingSeconds = Self.displaySeconds(session.remaining(at: now))
        startTimer()
        persistSession()
    }

    func pause() {
        guard session.status == .running else { return }
        let now = Date()
        session.pause(at: now)
        remainingSeconds = Self.displaySeconds(session.remaining(at: now))
        cancelTimer()
        if session.status == .completed {
            finishPhase()
        } else {
            persistSession()
        }
    }

    func resume() {
        guard session.status == .paused else { return }
        let now = Date()
        session.resume(at: now)
        guard session.status == .running else { return }
        remainingSeconds = Self.displaySeconds(session.remaining(at: now))
        startTimer()
        persistSession()
    }

    func setRemaining(minutes: Int) {
        guard session.status == .paused else { return }
        session.setRemaining(minutes: minutes)
        remainingSeconds = Self.displaySeconds(session.remaining())
        persistSession()
    }

    func addFiveMinutes() {
        guard session.status == .running else { return }
        let now = Date()
        session.addFiveMinutes(at: now)
        remainingSeconds = Self.displaySeconds(session.remaining(at: now))
        if session.status == .completed {
            finishPhase()
        } else {
            persistSession()
        }
    }

    func advancePhase() {
        guard session.nextPhase != nil else { return }
        cancelTimer()
        cancelCompletionNotice()
        let now = Date()
        session.advancePhase(at: now)
        remainingSeconds = Self.displaySeconds(session.remaining(at: now))
        startTimer()
        persistSession()
    }

    func stop() {
        cancelTimer()
        cancelCompletionNotice()
        session.end()
        remainingSeconds = 0
        persistSession()
    }

    func markReminderCompleted() {
        guard session.task?.reminderID != nil else { return }
        let wasRunning = session.status == .running
        session.detachReminder(at: Date())
        remainingSeconds = Self.displaySeconds(session.remaining())
        if wasRunning, session.status == .completed {
            finishPhase()
        } else {
            persistSession()
        }
    }

    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pause() }
        }
    }

    private func startTimer() {
        cancelTimer()
        guard session.status == .running else { return }
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.updateTimer(at: Date()) else { return }
            }
        }
    }

    private func updateTimer(at date: Date) -> Bool {
        guard session.status == .running else { return false }
        session.tick(at: date)
        remainingSeconds = Self.displaySeconds(session.remaining(at: date))
        guard session.status == .completed else { return true }
        finishPhase()
        return false
    }

    private func finishPhase() {
        remainingSeconds = 0
        cancelTimer()
        persistSession()
        showCompletionNotice()
    }

    private func showCompletionNotice() {
        completionNoticeTask?.cancel()
        completionNoticeVisible = true
        completionNoticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.completionNoticeVisible = false
            self?.completionNoticeTask = nil
        }
    }

    private func cancelTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func cancelCompletionNotice() {
        completionNoticeTask?.cancel()
        completionNoticeTask = nil
        completionNoticeVisible = false
    }

    private func persistSettings() {
        guard let data = try? JSONEncoder().encode(settings.sanitized) else { return }
        Defaults[.focusSettings] = data
    }

    private func persistSession() {
        guard let data = try? JSONEncoder().encode(session) else { return }
        Defaults[.focusSession] = data
    }

    private static func displaySeconds(_ seconds: TimeInterval) -> Int {
        max(0, Int(ceil(seconds)))
    }
}
