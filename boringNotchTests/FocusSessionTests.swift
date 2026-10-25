import Foundation
import EventKit
import XCTest

final class FocusSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testCountdownUsesElapsedTimeAndCompletesOnlyOnce() {
        var session = FocusSession.start(mode: .countdown, minutes: 1, at: start)

        session.tick(at: start.addingTimeInterval(20))
        session.tick(at: start.addingTimeInterval(40))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(50)), 10, accuracy: 0.001)

        session.tick(at: start.addingTimeInterval(61))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(100)), 0)
        session.tick(at: start.addingTimeInterval(200))
        XCTAssertEqual(session.completedWorkSessions, 1)
    }

    func testPauseAndResumePreserveTheExactRemainder() {
        var session = FocusSession.start(mode: .countdown, minutes: 1, at: start)

        session.pause(at: start.addingTimeInterval(12))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(500)), 48, accuracy: 0.001)
        session.pause(at: start.addingTimeInterval(30))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(500)), 48, accuracy: 0.001)

        session.resume(at: start.addingTimeInterval(100))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(130)), 18, accuracy: 0.001)
        session.pause(at: start.addingTimeInterval(130))
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(600)), 18, accuracy: 0.001)
    }

    func testPomodoroWaitsForManualAdvanceAndUsesLongBreakAfterFourthWork() {
        let settings = FocusSettings(workMinutes: 1, shortBreakMinutes: 1, longBreakMinutes: 2, longBreakInterval: 4)
        var session = FocusSession.start(mode: .pomodoro, minutes: 1, settings: settings, at: start)
        var phaseStarted = start

        for workCount in 1...4 {
            let workEnded = phaseStarted.addingTimeInterval(61)
            session.tick(at: workEnded)
            XCTAssertEqual(session.phase, .work)
            XCTAssertEqual(session.status, .completed)
            XCTAssertEqual(session.completedWorkSessions, workCount)
            XCTAssertEqual(session.nextPhase, workCount == 4 ? .longBreak : .shortBreak)

            session.advancePhase(at: workEnded)
            let expectedBreak: FocusPhase = workCount == 4 ? .longBreak : .shortBreak
            XCTAssertEqual(session.phase, expectedBreak)
            XCTAssertEqual(session.status, .running)

            let breakEnded = workEnded.addingTimeInterval(TimeInterval(expectedBreak == .longBreak ? 121 : 61))
            session.tick(at: breakEnded)
            XCTAssertEqual(session.phase, expectedBreak)
            XCTAssertEqual(session.status, .completed)
            XCTAssertEqual(session.completedWorkSessions, workCount)
            XCTAssertEqual(session.nextPhase, .work)

            session.advancePhase(at: breakEnded)
            XCTAssertEqual(session.phase, .work)
            phaseStarted = breakEnded
        }
    }

    func testSettingsSnapshotAndPausedCodableRoundTrip() throws {
        let settings = FocusSettings(workMinutes: 32, shortBreakMinutes: 8, longBreakMinutes: 19, longBreakInterval: 3)
        var session = FocusSession.start(mode: .pomodoro, minutes: 32, settings: settings, at: start)
        session.pause(at: start.addingTimeInterval(7))

        let restored = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.settings, settings)
    }

    func testRunningSnapshotRestoresPausedAtItsCheckpoint() throws {
        let session = FocusSession.start(mode: .countdown, minutes: 1, at: start)
        let restored = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(session))

        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(10_000)), 60, accuracy: 0.001)
        XCTAssertEqual(restored.anchorDate, nil)
    }

    func testInvalidSettingsAndDurationAreClamped() {
        let settings = FocusSettings(workMinutes: 0, shortBreakMinutes: 181, longBreakMinutes: -1, longBreakInterval: 0)
        XCTAssertEqual(settings.workMinutes, 1)
        XCTAssertEqual(settings.shortBreakMinutes, 180)
        XCTAssertEqual(settings.longBreakMinutes, 1)
        XCTAssertEqual(settings.longBreakInterval, 1)

        let session = FocusSession.start(mode: .countdown, minutes: 0, settings: settings, at: start)
        XCTAssertEqual(session.remaining(at: start), 60, accuracy: 0.001)
    }

    func testReminderDetachesWithoutChangingTaskTitleOrTimer() {
        let task = FocusTask(title: "Review draft", reminderID: "reminder-1", listName: "Work")
        var session = FocusSession.start(mode: .countdown, minutes: 1, task: task, at: start)

        session.detachReminder(at: start.addingTimeInterval(10))

        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(20)), 40, accuracy: 0.001)
        XCTAssertEqual(session.task?.title, "Review draft")
        XCTAssertNil(session.task?.reminderID)
        XCTAssertEqual(session.task?.listName, "Work")
    }

    func testDetachingReminderAtOrAfterDeadlineCompletesAndRestores() throws {
        let settings = FocusSettings(workMinutes: 1, shortBreakMinutes: 5, longBreakMinutes: 15, longBreakInterval: 4)

        for elapsed in [60.0, 61.0] {
            let task = FocusTask(title: "Review draft", reminderID: "reminder-1", listName: "Work")
            var session = FocusSession.start(mode: .pomodoro, minutes: 1, settings: settings, task: task, at: start)

            session.detachReminder(at: start.addingTimeInterval(elapsed))

            XCTAssertEqual(session.status, .completed)
            XCTAssertEqual(session.completedWorkSessions, 1)
            XCTAssertNil(session.task?.reminderID)

            var restored = try JSONDecoder().decode(FocusSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.status, .completed)
            XCTAssertEqual(restored.completedWorkSessions, 1)
            XCTAssertEqual(restored.nextPhase, .shortBreak)
            restored.resume(at: start.addingTimeInterval(10_000))
            XCTAssertEqual(restored.status, .completed)
            restored.advancePhase(at: start.addingTimeInterval(10_000))
            XCTAssertEqual(restored.phase, .shortBreak)
            XCTAssertEqual(restored.status, .running)
            XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(10_000)), 300, accuracy: 0.001)

            session.detachReminder(at: start.addingTimeInterval(elapsed + 60))
            XCTAssertEqual(session.completedWorkSessions, 1)
        }
    }

    func testCountdownCompletionStaysCompletedUntilEnded() {
        var session = FocusSession.start(mode: .countdown, minutes: 1, at: start)
        session.tick(at: start.addingTimeInterval(61))
        session.advancePhase(at: start.addingTimeInterval(62))
        XCTAssertEqual(session.status, .completed)

        session.end()
        XCTAssertEqual(session.status, .idle)
        XCTAssertNil(session.task)
        XCTAssertEqual(session.remaining(at: start), 0)
    }

    func testInvalidSettingsDecodeToSafeValues() throws {
        let data = Data(#"{"workMinutes":0,"shortBreakMinutes":-2,"longBreakMinutes":999,"longBreakInterval":0}"#.utf8)
        let settings = try JSONDecoder().decode(FocusSettings.self, from: data)

        XCTAssertEqual(settings.workMinutes, 1)
        XCTAssertEqual(settings.shortBreakMinutes, 1)
        XCTAssertEqual(settings.longBreakMinutes, 180)
        XCTAssertEqual(settings.longBreakInterval, 1)
    }

    func testFocusReminderMappingSortsDueFirstAndKeepsUndatedIncompleteTasks() {
        let dueDate = Date(timeIntervalSince1970: 1_800_000_000)
        let dueB = makeReminder(title: "Due B", due: dueDate.addingTimeInterval(86_400))
        let dueZ = makeReminder(title: "Due Z", due: dueDate)
        let dueA = makeReminder(title: "Due A", due: dueDate)
        let undatedB = makeReminder(title: "Undated B")
        let undatedA = makeReminder(title: "Undated A")
        let completed = makeReminder(title: "Completed", due: dueDate, completed: true)

        let tasks = FocusTask.fromReminders([undatedB, completed, dueB, dueZ, undatedA, dueA])

        XCTAssertEqual(tasks.map(\.title), ["Due A", "Due B", "Due Z", "Undated A", "Undated B"])
        XCTAssertEqual(tasks.map(\.reminderID), [dueA, dueB, dueZ, undatedA, undatedB].map(\.calendarItemIdentifier))
        XCTAssertEqual(tasks.map(\.listName), Array(repeating: "Focus tests", count: 5))
        XCTAssertEqual(FocusTask.fromReminders([dueA]).first?.reminderID, tasks[0].reminderID)
    }

    func testEmptyReminderCalendarSelectionDoesNotSelectEveryList() {
        let calendar = EKCalendar(for: .reminder, eventStore: reminderStore)

        XCTAssertTrue(matchingReminderCalendars(from: [calendar], selectedIDs: []).isEmpty)
    }

    func testFocusCompletionRequiresReminderListToRemainSelected() {
        let reminder = makeReminder(title: "Review draft")
        let calendarID = reminder.calendar!.calendarIdentifier

        XCTAssertTrue(reminderBelongsToSelectedList(reminder, selectedIDs: [calendarID]))
        XCTAssertFalse(reminderBelongsToSelectedList(reminder, selectedIDs: []))
        XCTAssertFalse(reminderBelongsToSelectedList(reminder, selectedIDs: ["different-list"]))
    }

    private let reminderStore = EKEventStore()

    private func makeReminder(title: String, due: Date? = nil, completed: Bool = false) -> EKReminder {
        let reminder = EKReminder(eventStore: reminderStore)
        reminder.title = title
        reminder.isCompleted = completed
        if let due {
            var components = Calendar.current.dateComponents([.year, .month, .day], from: due)
            components.calendar = Calendar.current
            reminder.dueDateComponents = components
        }
        let calendar = EKCalendar(for: .reminder, eventStore: reminderStore)
        calendar.title = "Focus tests"
        reminder.calendar = calendar
        return reminder
    }
}
