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

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Focus")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Picker("Focus mode", selection: $draftMode) {
                    Text("Countdown").tag(FocusMode.countdown)
                    Text("Pomodoro").tag(FocusMode.pomodoro)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!canEditSetup)
            }

            HStack(alignment: .center, spacing: 24) {
                setupColumn
                    .frame(width: 290, alignment: .leading)

                Spacer(minLength: 0)

                timerColumn
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

    @ViewBuilder
    private var setupColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            if canEditSetup {
                HStack(spacing: 8) {
                    Text("Duration")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if draftMode == .countdown {
                        Button("25 min") { draftMinutes = 25 }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("25 minutes")
                            .help("25 minutes")
                        Button("50 min") { draftMinutes = 50 }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("50 minutes")
                            .help("50 minutes")
                        Stepper("\(draftMinutes) min", value: $draftMinutes, in: 1...180)
                            .fixedSize()
                    } else {
                        Text("\(focusManager.settings.workMinutes) min work")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }

                Picker("Task source", selection: $taskSource) {
                    ForEach(FocusTaskSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if taskSource == .title {
                    TextField("Optional task title", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFieldFocused)
                        .onTapGesture { viewModel.beginFocusInteraction() }
                        .onKeyPress(.escape) {
                            titleFieldFocused = false
                            viewModel.endFocusInteraction()
                            return .handled
                        }
                } else if taskSource == .reminder {
                    HStack(spacing: 6) {
                        Button {
                            viewModel.beginFocusInteraction()
                            showingReminderPicker = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "list.bullet")
                                Text(selectedReminder?.title ?? String(localized: "Choose reminder"))
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Choose reminder")
                        .help("Choose reminder")

                        if reminderChoicesLoaded, selectedReminder != nil, !selectedReminderIsAvailable {
                            Text("Unavailable")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if focusManager.session.status != .idle {
                    Text("End the current session to change its task or mode.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: focusManager.session.task?.reminderID == nil ? "text.alignleft" : "checklist")
                        .foregroundStyle(.secondary)
                    Text(focusManager.session.task?.title ?? String(localized: "No task linked"))
                        .lineLimit(1)
                    if focusManager.session.task?.reminderID != nil,
                       reminderChoicesLoaded, !sessionReminderIsAvailable
                    {
                        Text("Unavailable")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)

                if let listName = focusManager.session.task?.listName {
                    Text(listName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("End the current session to change its task or mode.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let reminderID = focusManager.session.task?.reminderID {
                HStack(spacing: 8) {
                    Button {
                        Task { await completeReminder(id: reminderID) }
                    } label: {
                        Label(completingReminder ? "Saving…" : "Mark done", systemImage: "checkmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(completingReminder || !reminderChoicesLoaded || !sessionReminderIsAvailable)

                    if let reminderCompletionError {
                        Text(reminderCompletionError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
        .font(.subheadline)
    }

    private var timerColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(String(format: "%02d:%02d", focusManager.remainingSeconds / 60, focusManager.remainingSeconds % 60))
                .font(.system(size: 43, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .accessibilityLabel("Time remaining")

            HStack(spacing: 6) {
                Text(statusTitle)
                    .lineLimit(1)
                if focusManager.session.mode == .pomodoro, focusManager.session.completedWorkSessions > 0 {
                    Text("· \(focusManager.session.completedWorkSessions)")
                }
            }
            .font(.caption)
            .foregroundStyle(focusManager.session.status == .completed ? .green : .secondary)

            ProgressView(value: progress)
                .tint(focusManager.session.status == .completed ? .green : .accentColor)
                .frame(width: 250)
                .accessibilityLabel("Focus progress")

            HStack(spacing: 7) {
                switch focusManager.session.status {
                case .idle:
                    startButton
                case .running:
                    Button {
                        focusManager.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause focus timer")
                case .paused:
                    Button {
                        focusManager.resume()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume focus timer")
                case .completed:
                    if focusManager.session.mode == .pomodoro {
                        Button {
                            focusManager.advancePhase()
                        } label: {
                            Label("Next phase", systemImage: "arrow.right")
                        }
                        .help("Start the next Pomodoro phase")
                    } else {
                        startButton
                    }
                }

                if focusManager.session.status != .idle {
                    Button(role: .destructive) {
                        focusManager.stop()
                    } label: {
                        Label("End", systemImage: "stop.fill")
                    }
                    .help("End focus session")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var startButton: some View {
        Button {
            focusManager.start(
                mode: draftMode,
                minutes: draftMode == .pomodoro ? focusManager.settings.workMinutes : draftMinutes,
                task: newTask
            )
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .help("Start focus timer")
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
