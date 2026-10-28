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

private enum FocusTimeEditorTarget: Equatable {
    case setup
    case remaining
}

@MainActor
struct FocusView: View {
    @EnvironmentObject private var viewModel: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var focusManager = FocusManager.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    @FocusState private var titleFieldFocused: Bool
    @State private var draftMode: FocusMode = .countdown
    @State private var draftMinutes = 25
    @State private var draftPomodoroMinutes: Int?
    @State private var taskSource: FocusTaskSource = .none
    @State private var draftTitle = ""
    @State private var selectedReminder: FocusTask?
    @State private var showingSettings = false
    @State private var showingTimeEditor = false
    @State private var timeEditorMinutes = 25
    @State private var timeEditorTarget: FocusTimeEditorTarget?
    @State private var timeEditorSessionSnapshot: FocusSession?
    @State private var reminderChoicesLoaded = false
    @State private var completingReminder = false
    @State private var reminderCompletionError: String?

    private var canEditSetup: Bool {
        focusManager.session.status == .idle
            || (focusManager.session.status == .completed && focusManager.session.mode == .countdown)
    }

    private var setupMinutes: Int {
        draftMode == .pomodoro ? (draftPomodoroMinutes ?? focusManager.settings.workMinutes) : draftMinutes
    }

    private var canEditTime: Bool {
        canEditSetup || focusManager.session.status == .paused
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

    private var displayedTaskTitle: String {
        (canEditSetup ? newTask : focusManager.session.task)?.title ?? String(localized: "Focus session")
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
        return setupMinutes * 60
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            timerColumn
                .frame(minWidth: 155, idealWidth: 170, maxWidth: 180, alignment: .leading)
            detailsColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: taskSource) { _, source in
            reminderCompletionError = nil
            if source == .reminder {
                loadReminderChoices()
            } else {
                titleFieldFocused = false
            }
            updateFocusInteraction()
        }
        .onChange(of: titleFieldFocused) { _, _ in
            updateFocusInteraction()
        }
        .onChange(of: showingSettings) { _, showing in
            if showing, taskSource == .reminder, !reminderChoicesLoaded {
                loadReminderChoices()
            } else if !showing {
                titleFieldFocused = false
            }
            updateFocusInteraction()
        }
        .onChange(of: showingTimeEditor) { _, showing in
            if !showing {
                timeEditorTarget = nil
                timeEditorSessionSnapshot = nil
            }
            updateFocusInteraction()
        }
        .onChange(of: focusManager.session) { _, session in
            guard showingTimeEditor else { return }
            guard let snapshot = timeEditorSessionSnapshot,
                  session == snapshot,
                  durationTargetIsValid(timeEditorTarget, for: session) else {
                dismissTimeEditor()
                return
            }
        }
        .onChange(of: canEditSetup) { _, canEdit in
            guard !canEdit else { return }
            titleFieldFocused = false
            showingSettings = false
            dismissTimeEditor()
            updateFocusInteraction()
        }
        .onChange(of: coordinator.currentView) { _, view in
            guard view != .focus else { return }
            titleFieldFocused = false
            showingSettings = false
            dismissTimeEditor()
            updateFocusInteraction()
        }
        .task {
            guard focusManager.session.task?.reminderID != nil else { return }
            await calendarManager.loadFocusReminders()
            guard !Task.isCancelled, coordinator.currentView == .focus else { return }
            reminderChoicesLoaded = true
        }
        .onDisappear {
            titleFieldFocused = false
            showingSettings = false
            dismissTimeEditor()
            updateFocusInteraction()
        }
    }

    private var timerColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            timerControl

            Text(timerCaption)
                .font(.caption)
                .foregroundStyle(focusManager.session.status == .completed ? .green : .secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var timerControl: some View {
        if canEditTime {
            Button(action: toggleTimeEditor) {
                timerDisplay
            }
            .buttonStyle(.plain)
            .accessibilityLabel(timeAccessibilityLabel)
            .accessibilityValue(displayedTime)
            .help(timeAccessibilityLabel)
            .popover(isPresented: $showingTimeEditor, arrowEdge: .bottom) {
                timeEditor
            }
        } else {
            timerDisplay
                .accessibilityLabel("Time remaining")
                .accessibilityValue(displayedTime)
        }
    }

    private var timerDisplay: some View {
        Text(displayedTime)
            .font(.system(size: 44, weight: .medium, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.82)
            .lineLimit(1)
            .contentTransition(.numericText())
            .opacity(focusManager.completionNoticeVisible ? 0 : 1)
            .overlay {
                if focusManager.completionNoticeVisible {
                    Image(systemName: "checkmark")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
    }

    private var detailsColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text(displayedTaskTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(modeDurationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if reminderChoicesLoaded,
               ((!canEditSetup && focusManager.session.task?.reminderID != nil && !sessionReminderIsAvailable)
                || (canEditSetup && taskSource == .reminder && selectedReminder != nil && !selectedReminderIsAvailable))
            {
                Text("Reminder unavailable")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if let reminderCompletionError {
                Text(reminderCompletionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            FocusProgressBar(progress: progress, status: focusManager.session.status, reduceMotion: reduceMotion)
                .frame(height: 5)

            toolbar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeDurationSummary: String {
        let mode = canEditSetup ? draftMode : focusManager.session.mode
        let minutes: Int
        if canEditSetup {
            minutes = setupMinutes
        } else {
            minutes = max(1, Int((focusManager.session.durationSeconds / 60).rounded()))
        }
        let modeName = mode == .pomodoro ? String(localized: "Pomodoro") : String(localized: "Countdown")
        var items = ["\(modeName) · \(minutes) min"]
        if !canEditSetup, mode == .pomodoro, focusManager.session.completedWorkSessions > 0 {
            items.append("\(focusManager.session.completedWorkSessions) sessions")
        }
        if let listName = currentListName {
            items.append(listName)
        }
        return items.joined(separator: " · ")
    }

    private var currentListName: String? {
        if canEditSetup, taskSource == .reminder {
            selectedReminder?.listName
        } else {
            focusManager.session.task?.listName
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
            Label(taskSource.label, systemImage: taskSource.symbol)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Task source")
        .accessibilityValue(Text(taskSource.label))
        .help("Choose task source")
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

    private var taskConfiguration: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Task")
                    .font(.callout)
                Spacer()
                taskSourceMenu
            }

            switch taskSource {
            case .none:
                EmptyView()
            case .title:
                TextField("Optional task title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFieldFocused)
                    .onTapGesture { viewModel.beginFocusInteraction() }
                    .onKeyPress(.escape) {
                        titleFieldFocused = false
                        showingSettings = false
                        return .handled
                    }
            case .reminder:
                reminderChoices
            }
        }
    }

    @ViewBuilder
    private var reminderChoices: some View {
        if calendarManager.focusRemindersLoading {
            Label("Loading reminders…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        } else if reminderAccessDenied {
            VStack(alignment: .leading, spacing: 4) {
                Label("Reminders access denied.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("You can still use a title or run a timer without a task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                        } label: {
                            HStack(spacing: 6) {
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
                                Spacer(minLength: 0)
                                if selectedReminder?.reminderID == task.reminderID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedReminder?.reminderID == task.reminderID ? .isSelected : [])
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private var configurationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Focus setup")
                .font(.headline)

            HStack {
                Text("Mode")
                    .font(.callout)
                Spacer()
                modePicker
            }

            taskConfiguration
        }
        .padding(12)
        .frame(width: 300, alignment: .topLeading)
        .frame(minHeight: 90)
    }

    private var timeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(timeEditorTarget == .some(.remaining) ? "Remaining time" : "Focus duration")
                .font(.headline)

            HStack(spacing: 8) {
                Button("25") { timeEditorMinutes = min(25, timeEditorMaximumMinutes) }
                    .buttonStyle(.plain)
                    .foregroundStyle(timeEditorMinutes == 25 ? .primary : .secondary)
                    .disabled(timeEditorMaximumMinutes < 25)
                    .accessibilityLabel("25 minutes")
                    .help("25 minutes")
                Button("50") { timeEditorMinutes = min(50, timeEditorMaximumMinutes) }
                    .buttonStyle(.plain)
                    .foregroundStyle(timeEditorMinutes == 50 ? .primary : .secondary)
                    .disabled(timeEditorMaximumMinutes < 50)
                    .accessibilityLabel("50 minutes")
                    .help("50 minutes")
                Stepper(
                    "\(timeEditorMinutes) min",
                    value: $timeEditorMinutes,
                    in: 1...timeEditorMaximumMinutes
                )
                .font(.caption)
                .accessibilityLabel("Custom duration: \(timeEditorMinutes) minutes")
                .help("Adjust duration from 1 to \(timeEditorMaximumMinutes) minutes")
                .fixedSize()
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismissTimeEditor() }
                    .buttonStyle(.plain)
                Button("Apply", action: applyTimeEdit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .topLeading)
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            if let reminderID = focusManager.session.task?.reminderID {
                iconButton(
                    completingReminder ? "Saving reminder…" : "Mark reminder done",
                    systemName: completingReminder ? "hourglass" : "checkmark"
                ) {
                    Task { await completeReminder(id: reminderID) }
                }
                .disabled(completingReminder || !reminderChoicesLoaded || !sessionReminderIsAvailable)
            }

            Spacer(minLength: 0)

            switch focusManager.session.status {
            case .idle:
                startButton
            case .running:
                Button("+5 min") {
                    focusManager.addFiveMinutes()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .help("Add five minutes to the running focus timer")
                .accessibilityLabel("Add five minutes")
                .disabled(focusManager.session.durationSeconds >= 180 * 60)

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

            if canEditSetup {
                settingsButton
            }
        }
        .font(.subheadline)
    }

    private var settingsButton: some View {
        Button {
            if showingSettings {
                showingSettings = false
            } else {
                showingTimeEditor = false
                timeEditorTarget = nil
                timeEditorSessionSnapshot = nil
                titleFieldFocused = false
                showingSettings = true
                updateFocusInteraction()
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Configure focus timer")
        .accessibilityLabel("Configure focus timer")
        .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
            configurationPopover
        }
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
                minutes: setupMinutes,
                task: newTask
            )
            if draftMode == .pomodoro {
                draftPomodoroMinutes = nil
            }
        }
    }

    private var displayedTime: String {
        String(format: "%02d:%02d", displayedSeconds / 60, displayedSeconds % 60)
    }

    private var timeAccessibilityLabel: LocalizedStringKey {
        switch focusManager.session.status {
        case .idle: "Edit focus duration"
        case .paused: "Edit remaining time"
        case .completed where canEditSetup: "Edit focus duration"
        case .running, .completed: "Time remaining"
        }
    }

    private var timeEditorMaximumMinutes: Int {
        guard timeEditorTarget == .some(.remaining) else { return 180 }
        let elapsedSeconds = max(0, focusManager.session.durationSeconds - TimeInterval(focusManager.remainingSeconds))
        return max(1, min(180, Int(floor((180 * 60 - elapsedSeconds) / 60))))
    }

    private func toggleTimeEditor() {
        guard canEditTime else { return }
        guard !showingTimeEditor else {
            dismissTimeEditor()
            return
        }

        let target: FocusTimeEditorTarget
        if canEditSetup {
            target = .setup
        } else if focusManager.session.status == .paused {
            target = .remaining
        } else {
            return
        }

        timeEditorTarget = target
        timeEditorSessionSnapshot = focusManager.session
        switch target {
        case .setup:
            timeEditorMinutes = setupMinutes
        case .remaining:
            let roundedRemainingMinutes = max(1, (focusManager.remainingSeconds + 59) / 60)
            timeEditorMinutes = min(roundedRemainingMinutes, timeEditorMaximumMinutes)
        }

        titleFieldFocused = false
        showingSettings = false
        showingTimeEditor = true
        updateFocusInteraction()
    }

    private func applyTimeEdit() {
        guard let target = timeEditorTarget,
              let snapshot = timeEditorSessionSnapshot,
              focusManager.session == snapshot,
              durationTargetIsValid(target, for: focusManager.session) else {
            dismissTimeEditor()
            return
        }

        switch target {
        case .setup:
            if draftMode == .pomodoro {
                draftPomodoroMinutes = timeEditorMinutes
            } else {
                draftMinutes = timeEditorMinutes
            }
        case .remaining:
            focusManager.setRemaining(minutes: timeEditorMinutes)
        }
        dismissTimeEditor()
    }

    private func durationTargetIsValid(_ target: FocusTimeEditorTarget?, for session: FocusSession) -> Bool {
        switch target {
        case .some(.setup):
            session.status == .idle || (session.status == .completed && session.mode == .countdown)
        case .some(.remaining): session.status == .paused
        case .none: false
        }
    }

    private func dismissTimeEditor() {
        showingTimeEditor = false
        timeEditorTarget = nil
        timeEditorSessionSnapshot = nil
        updateFocusInteraction()
    }

    private func updateFocusInteraction() {
        if showingSettings || showingTimeEditor || titleFieldFocused {
            viewModel.beginFocusInteraction()
        } else {
            viewModel.endFocusInteraction()
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

    private func loadReminderChoices() {
        guard taskSource == .reminder else { return }
        Task {
            await calendarManager.loadFocusReminders()
            guard coordinator.currentView == .focus,
                  taskSource == .reminder,
                  showingSettings,
                  viewModel.isFocusInteracting else { return }
            reminderChoicesLoaded = true
        }
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

private struct FocusProgressBar: View {
    let progress: Double
    let status: FocusStatus
    let reduceMotion: Bool

    private let height: CGFloat = 5

    private var fraction: Double {
        min(1, max(0, progress))
    }

    private var tint: Color {
        switch status {
        case .paused: .secondary.opacity(0.45)
        case .completed: .green
        case .idle, .running: .accentColor
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let fillWidth = width * fraction
            let dotSize = min(7, width)
            let dotRadius = dotSize / 2
            let dotX = min(max(fillWidth, dotRadius), max(dotRadius, width - dotRadius))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: width, height: height)

                if fillWidth > 0 {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.72), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: fillWidth, height: height)
                        .overlay {
                            if status == .running && !reduceMotion && fillWidth >= 20 {
                                GeometryReader { bounds in
                                    let sweepWidth = min(28, bounds.size.width * 0.4)
                                    Rectangle()
                                        .fill(LinearGradient(
                                            colors: [.clear, .white.opacity(0.24), .clear],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ))
                                        .frame(width: sweepWidth, height: height)
                                        .phaseAnimator([false, true]) { sweep, phase in
                                            sweep.offset(x: phase ? max(0, bounds.size.width - sweepWidth) : 0)
                                        } animation: { _ in
                                            .linear(duration: 3.2)
                                        }
                                }
                                .clipShape(Capsule())
                                .accessibilityHidden(true)
                            }
                        }

                    if (status == .running || status == .paused) && fillWidth >= dotSize {
                        Circle()
                            .fill(.white.opacity(0.86))
                            .frame(width: dotSize, height: dotSize)
                            .position(x: dotX, y: height / 2)
                            .shadow(color: tint.opacity(status == .running ? 0.6 : 0.2), radius: 2)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Focus progress")
        .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
        .animation(status == .running && !reduceMotion ? .linear(duration: 0.9) : nil, value: fraction)
    }
}

struct FocusClosedActivity: View {
    let remainingSeconds: Int
    let completionNoticeVisible: Bool
    let onOpenFocus: () -> Void

    private var timeText: String {
        String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var body: some View {
        Button(action: onOpenFocus) {
            HStack(spacing: 4) {
                Image(systemName: completionNoticeVisible ? "checkmark.circle.fill" : "timer")
                    .font(.system(size: 10, weight: .semibold))
                Text(timeText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Focus")
        .accessibilityValue(Text(timeText))
        .help("Open Focus")
    }
}

#Preview {
    FocusView()
        .environmentObject(BoringViewModel())
        .frame(width: openNotchSize.width, height: openNotchSize.height)
}
