import Foundation
import EventKit

func matchingReminderCalendars(from calendars: [EKCalendar], selectedIDs: [String]) -> [EKCalendar] {
    guard !selectedIDs.isEmpty else { return [] }
    return calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
}

func reminderBelongsToSelectedList(_ reminder: EKReminder, selectedIDs: [String]) -> Bool {
    guard !selectedIDs.isEmpty, let calendar = reminder.calendar else { return false }
    return selectedIDs.contains(calendar.calendarIdentifier)
}

extension FocusTask {
    static func fromReminders(_ reminders: [EKReminder]) -> [FocusTask] {
        reminders
            .filter { !$0.isCompleted }
            .sorted { left, right in
                let leftHasDueDate = left.dueDateComponents != nil
                let rightHasDueDate = right.dueDateComponents != nil
                if leftHasDueDate != rightHasDueDate { return leftHasDueDate }

                let order = (left.title ?? "").localizedStandardCompare(right.title ?? "")
                if order != .orderedSame { return order == .orderedAscending }
                return left.calendarItemIdentifier < right.calendarItemIdentifier
            }
            .map { FocusTask(title: $0.title ?? "", reminderID: $0.calendarItemIdentifier, listName: $0.calendar?.title) }
    }
}
