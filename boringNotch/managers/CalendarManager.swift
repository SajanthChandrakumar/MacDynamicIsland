//
//  CalendarManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import Defaults
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var focusReminders: [FocusTask] = []
    @Published var focusRemindersLoading = false
    @Published var focusRemindersError: String?
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    private var selectedCalendars: [CalendarModel] = []
    private let calendarService = CalendarService()
    private var focusReminderLoadRequested = false
    private var focusReminderRequestID = 0
    private var focusReminderLoadGeneration = 0

    private var eventStoreChangedObserver: NSObjectProtocol?

    private init() {
        self.currentWeekStartDate = CalendarManager.startOfDay(Date())
        self.calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        self.reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        setupEventStoreChangedObserver()
        Task {
            await reloadCalendarAndReminderLists()
        }
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
                self.reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
                await self.reloadCalendarAndReminderLists()
                await self.refreshLoadedFocusReminders()
            }
        }
    }

    @MainActor
    func reloadCalendarAndReminderLists() async {
        let all = await calendarService.calendars()
        self.eventCalendars = all.filter { !$0.isReminder }
        self.reminderLists = all.filter { $0.isReminder }
        self.allCalendars = all // for legacy compatibility, can be removed if not needed
        updateSelectedCalendars()
    }

    func checkCalendarAuthorization() async {
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        switch calendarAuthorizationStatus {
        case .notDetermined:
            do {
                let granted = try await calendarService.requestAccess(to: .event)
                let status = EKEventStore.authorizationStatus(for: .event)
                calendarAuthorizationStatus = status == .notDetermined ? (granted ? .fullAccess : .denied) : status
            } catch {
                calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
                return
            }
            guard calendarAuthorizationStatus == .fullAccess else { return }
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .fullAccess, .authorized:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
            await updateEvents()
        case .writeOnly:
            NSLog("Write only")
        @unknown default:
            print("Unknown authorization status")
        }
    }
    
    func checkReminderAuthorization() async {
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        switch reminderAuthorizationStatus {
        case .notDetermined:
            do {
                let granted = try await calendarService.requestAccess(to: .reminder)
                let status = EKEventStore.authorizationStatus(for: .reminder)
                reminderAuthorizationStatus = status == .notDetermined ? (granted ? .fullAccess : .denied) : status
            } catch {
                reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
                focusReminders = []
                await reloadCalendarAndReminderLists()
                return
            }
            if hasReminderReadAccess(reminderAuthorizationStatus) {
                await reloadCalendarAndReminderLists()
            } else {
                focusReminders = []
                await reloadCalendarAndReminderLists()
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
            focusReminders = []
            await reloadCalendarAndReminderLists()
        case .fullAccess, .authorized:
            NSLog("Full access")
            await reloadCalendarAndReminderLists()
        case .writeOnly:
            NSLog("Write only")
            focusReminders = []
            await reloadCalendarAndReminderLists()
        @unknown default:
            print("Unknown authorization status")
        }
    }
        

    func updateSelectedCalendars() {
        // Populate selectedCalendarIDs based on Defaults calendar selection state
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

        // Update the local calendar objects that correspond to the selected ids
        selectedCalendars = allCalendars.filter { selectedCalendarIDs.contains($0.id) }
    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        return selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }

        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            selectionState =
                identifiers.isEmpty
                ? .all : identifiers.count == allCalendars.count ? .all : .selected(identifiers)  // if empty, select all
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        focusReminderRequestID += 1
        focusReminders = []
        focusRemindersError = nil
        await updateEvents()
        await refreshLoadedFocusReminders()
    }

    static func startOfDay(_ date: Date) -> Date {
        return Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents()
    }

    private func updateEvents() async {
        let calendarIDs = selectedCalendars.map { $0.id }
        let eventsResult = await calendarService.events(
            from: currentWeekStartDate,
            to: Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate)!,
            calendars: calendarIDs
        )
        self.events = eventsResult
    }

    func loadFocusReminders() async {
        focusReminderLoadGeneration += 1
        let loadGeneration = focusReminderLoadGeneration
        focusReminderRequestID += 1
        focusReminderLoadRequested = true
        focusRemindersLoading = true
        focusRemindersError = nil
        defer {
            if loadGeneration == focusReminderLoadGeneration {
                focusRemindersLoading = false
            }
        }

        let status = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = status
        if status == .notDetermined {
            do {
                let granted = try await calendarService.requestAccess(to: .reminder)
                guard loadGeneration == focusReminderLoadGeneration else { return }
                let updatedStatus = EKEventStore.authorizationStatus(for: .reminder)
                reminderAuthorizationStatus = updatedStatus == .notDetermined ? (granted ? .fullAccess : .denied) : updatedStatus
            } catch {
                guard loadGeneration == focusReminderLoadGeneration else { return }
                reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
                focusReminders = []
                focusRemindersError = error.localizedDescription
                await reloadCalendarAndReminderLists()
                return
            }
        }

        await reloadCalendarAndReminderLists()
        guard loadGeneration == focusReminderLoadGeneration else { return }
        guard hasReminderReadAccess(reminderAuthorizationStatus) else {
            focusReminders = []
            focusRemindersError = "Reminders access is required to choose a reminder."
            return
        }
        await refreshFocusReminders()
    }

    private func refreshLoadedFocusReminders() async {
        guard focusReminderLoadRequested else { return }
        await refreshFocusReminders()
    }

    private func refreshFocusReminders() async {
        focusReminderRequestID += 1
        let requestID = focusReminderRequestID
        let status = EKEventStore.authorizationStatus(for: .reminder)
        reminderAuthorizationStatus = status
        guard hasReminderReadAccess(status) else {
            focusReminders = []
            focusRemindersError = "Reminders access is required to choose a reminder."
            return
        }

        let calendarIDs = reminderLists.filter { selectedCalendarIDs.contains($0.id) }.map(\.id)
        guard !calendarIDs.isEmpty else {
            focusReminders = []
            focusRemindersError = nil
            return
        }

        let reminders = await calendarService.focusReminders(in: calendarIDs)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard requestID == focusReminderRequestID else { return }
        guard hasReminderReadAccess(reminderAuthorizationStatus) else {
            focusReminders = []
            focusRemindersError = "Reminders access is required to choose a reminder."
            return
        }
        focusReminders = reminders
        focusRemindersError = nil
    }

    private func hasReminderReadAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess
    }

    func completeFocusReminder(id: String) async throws {
        try calendarService.setReminderCompleted(
            reminderID: id,
            completed: true,
            selectedCalendarIDs: reminderLists.filter { selectedCalendarIDs.contains($0.id) }.map(\.id)
        )
        focusReminderLoadRequested = true
        await reloadCalendarAndReminderLists()
        await refreshFocusReminders()
        await updateEvents()
    }
    
    func setReminderCompleted(reminderID: String, completed: Bool) async {
        do {
            try await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        } catch {
            NSLog("Failed to update reminder completion: %@", error.localizedDescription)
        }
        await updateEvents()
    }
}
