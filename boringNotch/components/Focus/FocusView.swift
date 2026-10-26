import AppKit
import EventKit
import SwiftUI

private enum FocusTaskSource: String, CaseIterable {
    case none
    case title
    case reminder

    var label: LocalizedStringKey {
        switch self {
        case .none: "No task"
        case .title: "Title"
        case .reminder: "Reminder"
        }
    }

    var symbol: String {
        switch self {
        case .none: "text.alignleft"
        case .title: "pencil.line"
        case .reminder: "checklist"
        }
    }
}

@MainActor
struct FocusView: View {
    @EnvironmentObject private var viewModel: BoringViewModel
    @ObservedObject private var focusManager = FocusManager.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    @FocusState private var titleFieldFocused: Bool
    @State private var draftMode: FocusMode = .countdown
    @State private var draftMinutes = 25
    @State private var taskSource: FocusTaskSource = .none
    @State private var draftTitle = ""
    @State private var selectedReminder: FocusTask?
    @State private var showingReminderPicker = false
    @State private var reminderChoicesLoaded = false
    @State private var completingReminder = false
    @State private var reminderCompletionError: String?

    private var canEditSetup: Bool {
        focusManager.session.status == .idle
            || (focusManager.session.status == .completed && focusManager.session.mode == .countdown)
    }

    private var newTask: FocusTask? {
        switch taskSource {
        case .none:
            return nil
        case .title:
            let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : FocusTask(title: title)
        case .reminder:
            return selectedReminder
        }
    }

    private var sessionReminderIsAvailable: Bool {
        guard let reminderID = focusManager.session.task?.reminderID else { return false }
        return calendarManager.focusReminders.contains { $0.reminderID == reminderID }
    }

    private var selectedReminderIsAvailable: Bool {
        guard let reminderID = selectedReminder?.reminderID else { return false }
        return calendarManager.focusReminders.contains { $0.reminderID == reminderID }
    }

    private var reminderAccessDenied: Bool {
        calendarManager.reminderAuthorizationStatus == .denied
            || calendarManager.reminderAuthorizationStatus == .restricted
            || calendarManager.reminderAuthorizationStatus == .writeOnly
    }

    private var displayedSeconds: Int {
        guard focusManager.session.status == .idle else { return focusManager.remainingSeconds }
        let minutes = draftMode == .pomodoro ? focusManager.settings.workMinutes : draftMinutes
        return minutes * 60
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            timerTile
            detailsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: taskSource) { _, source in
            reminderCompletionError = nil
            if source == .reminder {
                viewModel.beginFocusInteraction()
                Task {
                    await loadReminders()
                    guard coordinator.currentView == .focus,
                          taskSource == .reminder,
                          viewModel.isFocusInteracting else { return }
                    showingReminderPicker = true
                }
            } else {
                titleFieldFocused = false
                showingReminderPicker = false
                viewModel.endFocusInteraction()
            }
        }
        .onChange(of: titleFieldFocused) { _, focused in
            if focused {
                viewModel.beginFocusInteraction()
            } else if taskSource != .reminder {
                viewModel.endFocusInteraction()
            }
        }
        .onChange(of: showingReminderPicker) { _, showing in
            if !showing {
                viewModel.endFocusInteraction()
            }
        }
        .onChange(of: coordinator.currentView) { _, view in
            guard view != .focus else { return }
            titleFieldFocused = false
            showingReminderPicker = false
            viewModel.endFocusInteraction()
        }
        .popover(isPresented: $showingReminderPicker) {
            reminderPicker
        }
        .onAppear {
            if focusManager.session.task?.reminderID != nil {
                Task { await loadReminders() }
            }
        }
        .onDisappear {
            titleFieldFocused = false
            showingReminderPicker = false
            viewModel.endFocusInteraction()
        }
    }

    private var timerTile: some View {
        VStack(spacing: 5) {
            Text(String(format: "%02d:%02d", displayedSeconds / 60, displayedSeconds % 60))
                .font(.system(size: 25, weight: .medium, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())
                .accessibilityLabel("Time remaining")

            Text(timerCaption)
                .font(.caption2)
                .foregroundStyle(focusManager.session.status == .completed ? .green : .secondary)
                .lineLimit(1)
        }
        .frame(width: 90, height: 90)
        .background(Color(nsColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 13))
    }

    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleRow
            statusRow
            if let reminderCompletionError {
                Text(reminderCompletionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            ProgressView(value: progress)
                .tint(focusManager.session.status == .completed ? .green : .accentColor)
                .accessibilityLabel("Focus progress")
            toolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            if canEditSetup {
                taskSourceMenu
                switch taskSource {
                case .none:
                    Text("Focus session")
                        .font(.headline)
                        .lineLimit(1)
                case .title:
                    TextField("Optional task title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.headline)
                        .focused($titleFieldFocused)
                        .onTapGesture { viewModel.beginFocusInteraction() }
                        .onKeyPress(.escape) {
                            titleFieldFocused = false
                            viewModel.endFocusInteraction()
                            return .handled
                        }
                case .reminder:
                    reminderButton
                }

                Spacer(minLength: 4)
                modePicker
            } else {
                Text(focusManager.session.task?.title ?? String(localized: "Focus session"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(focusManager.session.mode == .pomodoro
                    ? String(localized: "Pomodoro")
                    : String(localized: "Countdown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var taskSourceMenu: some View {
        Menu {
            ForEach(FocusTaskSource.allCases, id: \.self) { source in
                Button {
                    taskSource = source
                } label: {
                    if taskSource == source {
                        Label(source.label, systemImage: "checkmark")
                    } else {
                        Text(source.label)
                    }
                }
            }
        } label: {
            Image(systemName: taskSource.symbol)
                .frame(width: 22, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Task source")
        .accessibilityValue(Text(taskSource.label))
        .help("Choose task source")
    }

    private var reminderButton: some View {
        HStack(spacing: 5) {
            Button {
                viewModel.beginFocusInteraction()
                showingReminderPicker = true
            } label: {
                Text(selectedReminder?.title ?? String(localized: "Choose reminder"))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose reminder")
            .help("Choose reminder")

        }
    }

    private var modePicker: some View {
        Picker("Focus mode", selection: $draftMode) {
            Text("Countdown").tag(FocusMode.countdown)
            Text("Pomodoro").tag(FocusMode.pomodoro)
        }
        .pickerStyle(.menu)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .labelsHidden()
        .accessibilityLabel("Focus mode")
        .disabled(!canEditSetup)
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Text(statusTitle)
                .lineLimit(1)
            if focusManager.session.mode == .pomodoro, focusManager.session.completedWorkSessions > 0 {
                Text("· \(focusManager.session.completedWorkSessions)")
            }
            if let listName = currentListName {
                Text("· \(listName)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if reminderChoicesLoaded,
               ((!canEditSetup && focusManager.session.task?.reminderID != nil && !sessionReminderIsAvailable)
                || (canEditSetup && taskSource == .reminder && selectedReminder != nil && !selectedReminderIsAvailable))
            {
                Text("Unavailable")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if let reminderID = focusManager.session.task?.reminderID {
                Button {
                    Task { await completeReminder(id: reminderID) }
                } label: {
                    Image(systemName: completingReminder ? "hourglass" : "checkmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(completingReminder ? "Saving…" : "Mark done")
                .help(completingReminder ? "Saving…" : "Mark done")
                .disabled(completingReminder || !reminderChoicesLoaded || !sessionReminderIsAvailable)
            }
        }
        .font(.caption)
        .foregroundStyle(focusManager.session.status == .completed ? .green : .secondary)
    }

    private var currentListName: String? {
        if canEditSetup, taskSource == .reminder {
            selectedReminder?.listName
        } else {
            focusManager.session.task?.listName
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            if canEditSetup {
                if draftMode == .countdown {
                    Button("25") { draftMinutes = 25 }
                        .buttonStyle(.plain)
                        .foregroundStyle(draftMinutes == 25 ? .primary : .secondary)
                        .accessibilityLabel("25 minutes")
                        .help("25 minutes")
                    Button("50") { draftMinutes = 50 }
                        .buttonStyle(.plain)
                        .foregroundStyle(draftMinutes == 50 ? .primary : .secondary)
                        .accessibilityLabel("50 minutes")
                        .help("50 minutes")
                    Stepper("\(draftMinutes) min", value: $draftMinutes, in: 1...180)
                        .font(.caption)
                        .accessibilityLabel("Custom duration: \(draftMinutes) minutes")
                        .help("Adjust duration from 1 to 180 minutes")
                        .fixedSize()
                } else {
                    Text("\(focusManager.settings.workMinutes) min work")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            switch focusManager.session.status {
            case .idle:
                startButton
            case .running:
                iconButton("Pause focus timer", systemName: "pause.fill") {
                    focusManager.pause()
                }
            case .paused:
                iconButton("Resume focus timer", systemName: "play.fill") {
                    focusManager.resume()
                }
            case .completed:
                if focusManager.session.mode == .pomodoro {
                    iconButton("Start the next Pomodoro phase", systemName: "arrow.right") {
                        focusManager.advancePhase()
                    }
                } else {
                    startButton
                }
            }

            if focusManager.session.status != .idle {
                iconButton("End focus session", systemName: "stop.fill", role: .destructive) {
                    focusManager.stop()
                }
            }
        }
        .font(.subheadline)
    }

    private var timerCaption: String {
        switch focusManager.session.status {
        case .idle: draftMode == .pomodoro ? String(localized: "Pomodoro") : String(localized: "Ready")
        case .running: statusTitle
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        }
    }

    private var startButton: some View {
        iconButton("Start focus timer", systemName: "play.fill") {
            focusManager.start(
                mode: draftMode,
                minutes: draftMode == .pomodoro ? focusManager.settings.workMinutes : draftMinutes,
                task: newTask
            )
        }
    }

    private func iconButton(
        _ title: LocalizedStringKey,
        systemName: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private var progress: Double {
        let duration = focusManager.session.durationSeconds
        guard duration > 0 else { return 0 }
        return min(1, max(0, 1 - Double(focusManager.remainingSeconds) / duration))
    }

    private var statusTitle: String {
        switch focusManager.session.status {
        case .idle: String(localized: "Ready to focus")
        case .running:
            switch focusManager.session.phase {
            case .work: String(localized: "Work")
            case .shortBreak: String(localized: "Short break")
            case .longBreak: String(localized: "Long break")
            }
        case .paused: String(localized: "Paused")
        case .completed:
            if focusManager.completionNoticeVisible {
                String(localized: "Phase complete")
            } else if focusManager.session.nextPhase != nil {
                String(localized: "Ready for next phase")
            } else {
                String(localized: "Completed")
            }
        }
    }

    private var reminderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a reminder")
                .font(.headline)

            if calendarManager.focusRemindersLoading {
                Label("Loading reminders…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if reminderAccessDenied {
                Label("Reminders access denied.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("You can still use a title or run a timer without a task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = calendarManager.focusRemindersError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if calendarManager.focusReminders.isEmpty {
                Text("No reminders available.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(calendarManager.focusReminders, id: \.reminderID) { task in
                            Button {
                                selectedReminder = task
                                showingReminderPicker = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .lineLimit(1)
                                    if let listName = task.listName {
                                        Text(listName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .frame(minHeight: 80)
    }

    private func loadReminders() async {
        await calendarManager.loadFocusReminders()
        reminderChoicesLoaded = true
    }

    private func completeReminder(id: String) async {
        guard !completingReminder else { return }
        completingReminder = true
        reminderCompletionError = nil
        defer { completingReminder = false }

        do {
            try await calendarManager.completeFocusReminder(id: id)
            guard focusManager.session.task?.reminderID == id else { return }
            focusManager.markReminderCompleted()
        } catch {
            reminderCompletionError = error.localizedDescription
        }
    }
}

struct FocusClosedActivity: View {
    let remainingSeconds: Int
    let completionNoticeVisible: Bool
    let musicCover: NSImage
    let showsMusicCover: Bool
    let leftWidth: CGFloat
    let centerWidth: CGFloat
    let rightWidth: CGFloat
    let onOpenFocus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenFocus) {
                HStack(spacing: 4) {
                    Image(systemName: completionNoticeVisible ? "checkmark.circle.fill" : "timer")
                        .font(.system(size: 10, weight: .semibold))
                    Text(String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: leftWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Focus")
            .help("Open Focus")

            Rectangle()
                .fill(.black)
                .frame(width: centerWidth)

            if showsMusicCover {
                Image(nsImage: musicCover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: rightWidth, height: rightWidth)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
                    .accessibilityLabel("Now playing album artwork")
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.gray)
                    .frame(width: rightWidth)
                    .accessibilityLabel("Focus timer active")
            }
        }
        .frame(height: 26)
    }
}

#Preview {
    FocusView()
        .environmentObject(BoringViewModel())
        .frame(width: openNotchSize.width, height: openNotchSize.height)
}
