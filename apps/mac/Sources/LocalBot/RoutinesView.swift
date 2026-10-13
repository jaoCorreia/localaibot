import SwiftUI

/// A bot's routines: tasks it runs on its own, on a schedule.
struct RoutinesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain
    let bot: Brain.Bot

    private var routines: [Brain.Routine] { brain.routines.filter { $0.botId == bot.id } }

    var body: some View {
        VStack(spacing: 0) {
            if routines.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(routines) { r in RoutineCard(model: model, brain: brain, routine: r) }
                    }
                    .padding(14)
                    .thinScrollers()
                }
                .fadesUnderTopBar(Theme.sidebar)
            }
            PillButton(title: "New routine", systemImage: "plus", prominent: true) {
                model.sheet = .routine(botID: bot.id, routineID: nil)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
        }
        .task { await brain.refreshRoutines() }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.tertiary)
            Text("No routines yet").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            Text("Routines are tasks \(bot.name) does on its own, on a schedule, even when you’re away.")
                .font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.examples, id: \.self) { ex in
                    Label(ex, systemImage: "sparkle").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    static let examples = [
        "Every weekday at 9:00, summarize my inbox",
        "Every hour, check the status page and warn me if it’s down",
        "Every Monday, collect last week’s sales numbers",
    ]
}

struct RoutineCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain
    let routine: Brain.Routine
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 12))
                    .foregroundStyle(routine.enabled ? Theme.text : Theme.tertiary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.raised))
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(routine.scheduleText).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { routine.enabled }, set: { on in Task { await brain.setRoutineEnabled(routine.id, on) } }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel("Enabled")
                Menu {
                    Button("Run now") { Task { await brain.runRoutineNow(routine.id) } }
                        .disabled(routine.lastStatus == "running" || brain.thinking.contains(routine.botId))
                    Button("Edit…") { model.sheet = .routine(botID: routine.botId, routineID: routine.id) }
                    Divider()
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.raised.opacity(0.7)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .accessibilityLabel("Routine actions")
            }

            Text(routine.task).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .lineLimit(2).padding(.leading, 38)

            HStack(spacing: 10) {
                status
                Spacer()
                if routine.enabled, let next = date(routine.nextRunAt), routine.lastStatus != "running" {
                    Label("Next \(relative(next))", systemImage: "clock").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.leading, 38)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .hairline(12)
        .opacity(routine.enabled || routine.lastStatus == "running" ? 1 : 0.7)
        .confirmationDialog("Delete “\(routine.name)”?", isPresented: $confirmDelete) {
            Button("Delete routine", role: .destructive) { Task { await brain.deleteRoutine(routine.id) } }
        } message: {
            Text("Past runs stay in the chat.")
        }
    }

    private var icon: String {
        switch routine.schedule {
        case .interval: return "repeat"
        case .daily: return "calendar"
        case .once: return "calendar.badge.clock"
        }
    }

    @ViewBuilder private var status: some View {
        switch routine.lastStatus {
        case "running":
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Running now").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
            }
        case "ok":
            Label("Ran \(relative(date(routine.lastRunAt)))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.live)
        case "failed":
            Label(routine.lastError.map { "Failed: \($0)" } ?? "Failed", systemImage: "exclamationmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(1)
        default:
            Text("Hasn’t run yet").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
        }
    }

    private func date(_ iso: String?) -> Date? {
        iso.flatMap { ISO8601DateFormatter.withFractions.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: .now)
    }
}

/// Create or edit a routine: what to do, and when.
struct RoutineEditor: View {
    @ObservedObject var brain: Brain
    let botID: String
    let routineID: String?
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case daily = "Daily", interval = "Repeat", once = "Once"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var task = ""
    @State private var kind: Kind = .daily
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    @State private var days: Set<Int> = [1, 2, 3, 4, 5]
    @State private var every = 1
    @State private var unit = "hours"
    @State private var onceAt = Date.now.addingTimeInterval(3600)
    @State private var enabled = true
    @State private var saving = false

    private var bot: Brain.Bot? { brain.bots.first { $0.id == botID } }
    private var existing: Brain.Routine? { routineID.flatMap { id in brain.routines.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                if let bot { AnimatedFace(face: bot.face, size: 36, seed: bot.id) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New routine" : "Edit routine").font(.system(size: 17, weight: .semibold))
                    Text("\(bot?.name ?? "The bot") will do this on its own, on schedule.")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                IconButton(systemImage: "xmark", help: "Close") { dismiss() }
            }

            Field(label: "Name", text: $name, placeholder: "e.g. Morning inbox summary")
            Field(label: "What should it do?", text: $task,
                  placeholder: "Open Gmail, read the unread emails from today and send me a short summary of what needs a reply.",
                  axis: .vertical)

            VStack(alignment: .leading, spacing: 10) {
                Text("When").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)

                switch kind {
                case .daily:
                    HStack(spacing: 12) {
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().frame(width: 90)
                        DayChips(days: $days)
                    }
                case .interval:
                    HStack(spacing: 8) {
                        Text("Every").font(.system(size: 12))
                        TextField("", value: $every, format: .number)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .frame(width: 44).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface)).hairline(7)
                        Stepper("", value: $every, in: 1...999).labelsHidden()
                        Picker("", selection: $unit) {
                            Text("minutes").tag("minutes")
                            Text("hours").tag("hours")
                        }
                        .labelsHidden().frame(width: 100)
                    }
                    if unit == "minutes" && every < 5 {
                        Text("The minimum is every 5 minutes.").font(.system(size: 11)).foregroundStyle(Theme.warn)
                    }
                case .once:
                    DatePicker("", selection: $onceAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().frame(width: 220)
                }
            }

            Toggle("Enabled", isOn: $enabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 12))

            HStack {
                Spacer()
                PillButton(title: "Cancel", systemImage: "xmark") { dismiss() }
                PillButton(title: saving ? "Saving…" : (existing == nil ? "Create routine" : "Save"), systemImage: "checkmark", prominent: true) { save() }
                    .disabled(!valid || saving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.sidebar)
        .onAppear(perform: load)
    }

    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .daily: return true
        case .interval: return every >= (unit == "minutes" ? 5 : 1)
        case .once: return onceAt > .now
        }
    }

    private var schedule: Brain.Schedule {
        switch kind {
        case .daily:
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return .daily(time: String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0), days: days.sorted())
        case .interval:
            return .interval(every: every, unit: unit)
        case .once:
            return .once(at: onceAt)
        }
    }

    private func load() {
        guard let r = existing else { return }
        name = r.name
        task = r.task
        enabled = r.enabled
        switch r.schedule {
        case .daily(let t, let d):
            kind = .daily
            days = Set(d)
            let parts = t.split(separator: ":").compactMap { Int($0) }
            time = Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.last ?? 0, second: 0, of: .now) ?? time
        case .interval(let e, let u):
            kind = .interval; every = e; unit = u
        case .once(let at):
            kind = .once; onceAt = at
        }
    }

    private func save() {
        saving = true
        Task {
            if await brain.saveRoutine(id: routineID, botId: botID, name: name, task: task, schedule: schedule, enabled: enabled) {
                dismiss()
            }
            saving = false
        }
    }
}

/// S M T W T F S toggles; none selected means every day.
struct DayChips: View {
    @Binding var days: Set<Int>
    private let letters = ["S", "M", "T", "W", "T", "F", "S"]
    private let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { d in
                let on = days.contains(d)
                Button {
                    if on { days.remove(d) } else { days.insert(d) }
                } label: {
                    Text(letters[d]).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(on ? Theme.onText : Theme.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(on ? Theme.text : Theme.surface))
                        .overlay(Circle().stroke(on ? Color.clear : Theme.border))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[d])
                .accessibilityValue(on ? "selected" : "not selected")
            }
            Text(days.isEmpty || days.count == 7 ? "Every day" : days.sorted() == [1, 2, 3, 4, 5] ? "Weekdays" : "")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).padding(.leading, 4)
        }
    }
}
