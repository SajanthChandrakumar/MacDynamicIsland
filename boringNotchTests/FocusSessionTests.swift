import Foundation
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
}
