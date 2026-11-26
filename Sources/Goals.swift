import SwiftUI
import Charts

// MARK: - Model

struct Goal: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var startBPM: Int
    var targetBPM: Int
    var dailyReps: Int
    var created = Date()
    // Tempo ladder
    var stepBPM: Int = 5          // jump between steps
    var passReps: Int = 10        // clean reps needed in one session to pass a step
    var passedSteps: Int = 0
    var locked: Bool = true       // metronome locked to the current step's tempo

    init(name: String, startBPM: Int, targetBPM: Int, dailyReps: Int) {
        self.name = name; self.startBPM = startBPM; self.targetBPM = targetBPM; self.dailyReps = dailyReps
    }

    /// Every tempo on the ladder, start → target.
    var ladder: [Int] {
        let step = max(stepBPM, 1)
        guard targetBPM > startBPM else { return [startBPM] }
        var v = Array(stride(from: startBPM, to: targetBPM, by: step))
        v.append(targetBPM)
        return v
    }
    var isComplete: Bool { passedSteps >= ladder.count }
    var currentBPM: Int { ladder[min(passedSteps, ladder.count - 1)] }
    var nextBPM: Int? { passedSteps + 1 < ladder.count ? ladder[passedSteps + 1] : nil }

    enum CodingKeys: String, CodingKey {
        case id, name, startBPM, targetBPM, dailyReps, created, stepBPM, passReps, passedSteps, locked
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        startBPM = try c.decode(Int.self, forKey: .startBPM)
        targetBPM = try c.decode(Int.self, forKey: .targetBPM)
        dailyReps = try c.decode(Int.self, forKey: .dailyReps)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        stepBPM = try c.decodeIfPresent(Int.self, forKey: .stepBPM) ?? 5
        passReps = try c.decodeIfPresent(Int.self, forKey: .passReps) ?? 10
        passedSteps = try c.decodeIfPresent(Int.self, forKey: .passedSteps) ?? 0
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
    }
}

/// Outcome of a session against the active goal's ladder.
struct StepOutcome {
    let goalName: String
    let stepBPM: Int
    let needed: Int
    let got: Int
    let passed: Bool
    let wrongTempo: Bool
    let nextBPM: Int?
    let goalComplete: Bool
}

struct PracticeSession: Identifiable, Codable, Hashable {
    var id = UUID()
    var date = Date()
    var goalID: UUID?
    var bpm: Int
    var meter: String
    var reps: Int
    var bars: Int
    var minutes: Double
    var cleanReps: Int? = nil      // set when Kick check was on
    var avgErrorMs: Double? = nil
    var spreadMs: Double? = nil
    /// Reps that count toward goals: clean reps if the mic was listening.
    var countedReps: Int { cleanReps ?? reps }
}

final class GoalStore: ObservableObject {
    @Published var goals: [Goal] = [] { didSet { save() } }
    @Published var sessions: [PracticeSession] = [] { didSet { save() } }
    @Published var activeGoalID: UUID? { didSet { save() } }

    private let key = "spokenMetronome.goals.v1"
    private struct Saved: Codable { var goals: [Goal]; var sessions: [PracticeSession]; var active: UUID? }
    private var loading = false

    init() {
        loading = true
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Saved.self, from: data) {
            goals = s.goals; sessions = s.sessions; activeGoalID = s.active
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let s = Saved(goals: goals, sessions: sessions, active: activeGoalID)
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key) }
    }

    var activeGoal: Goal? { goals.first { $0.id == activeGoalID } }

    func log(_ s: PracticeSession) { sessions.insert(s, at: 0) }

    /// Tempo the metronome must use, if the active goal is locked.
    var lockedBPM: Int? {
        guard let g = activeGoal, g.locked, !g.isComplete else { return nil }
        return g.currentBPM
    }

    /// Check a finished session against the active goal and advance the ladder if passed.
    func evaluate(_ s: PracticeSession) -> StepOutcome? {
        guard let i = goals.firstIndex(where: { $0.id == s.goalID }), !goals[i].isComplete else { return nil }
        let g = goals[i]
        let wrong = s.bpm != g.currentBPM
        let passed = !wrong && s.countedReps >= g.passReps
        if passed { goals[i].passedSteps += 1 }
        let ng = goals[i]
        return StepOutcome(goalName: g.name, stepBPM: g.currentBPM, needed: g.passReps, got: s.countedReps,
                           passed: passed, wrongTempo: wrong,
                           nextBPM: passed ? (ng.isComplete ? nil : ng.currentBPM) : nil,
                           goalComplete: ng.isComplete)
    }

    func delete(_ g: Goal) {
        goals.removeAll { $0.id == g.id }
        sessions.removeAll { $0.goalID == g.id }
        if activeGoalID == g.id { activeGoalID = goals.first?.id }
    }

    func sessions(for g: Goal) -> [PracticeSession] { sessions.filter { $0.goalID == g.id } }

    func bestBPM(_ g: Goal) -> Int { sessions(for: g).filter { $0.countedReps > 0 }.map(\.bpm).max() ?? g.startBPM }

    func progress(_ g: Goal) -> Double {
        return Double(min(g.passedSteps, g.ladder.count)) / Double(max(g.ladder.count, 1))
    }

    func speedProgress(_ g: Goal) -> Double {
        let span = Double(g.targetBPM - g.startBPM)
        guard span > 0 else { return bestBPM(g) >= g.targetBPM ? 1 : 0 }
        return min(max(Double(bestBPM(g) - g.startBPM) / span, 0), 1)
    }

    func repsToday(_ g: Goal) -> Int {
        sessions(for: g).filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.countedReps }
    }

    /// Consecutive days (ending today or yesterday) with at least one rep.
    func streak(_ g: Goal) -> Int {
        let cal = Calendar.current
        let days = Set(sessions(for: g).filter { $0.countedReps > 0 }.map { cal.startOfDay(for: $0.date) })
        var day = cal.startOfDay(for: Date())
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        var n = 0
        while days.contains(day) { n += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        return n
    }
}

// MARK: - Goals tab

struct GoalsView: View {
    @ObservedObject var store: GoalStore
    @ObservedObject var m: MetronomeEngine
    @State private var editing: Goal?
    @State private var showNew = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Text("Goals").font(.system(size: 34, weight: .heavy, design: .rounded))
                        Spacer()
                        Button { showNew = true } label: {
                            Image(systemName: "plus").font(.title3.weight(.bold)).foregroundStyle(.black)
                                .frame(width: 44, height: 44).background(Circle().fill(Theme.beat))
                        }
                    }
                    .padding(.top, 8)

                    if store.goals.isEmpty { empty }
                    ForEach(store.goals) { g in goalCard(g) }
                    if !store.sessions.isEmpty { history }
                    Color.clear.frame(height: 20)
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
        }
        .sheet(isPresented: $showNew) {
            GoalEditor(goal: Goal(name: "", startBPM: Int(m.bpm), targetBPM: Int(m.bpm) + 20, dailyReps: 10)) { g in
                store.goals.append(g)
                if store.activeGoalID == nil { store.activeGoalID = g.id }
            }
        }
        .sheet(item: $editing) { g in
            GoalEditor(goal: g) { new in
                if let i = store.goals.firstIndex(where: { $0.id == new.id }) { store.goals[i] = new }
            }
        }
    }

    private var empty: some View {
        Card(title: "No goals yet", icon: "target") {
            Text("Set a target tempo — like “Paradiddles at 140” — then use Loop on the metronome. Every finished rep is logged here so you can watch your speed climb.")
                .foregroundStyle(Theme.dim)
            Button { showNew = true } label: {
                Label("Create a goal", systemImage: "plus")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 46)
                    .background(Capsule().fill(Theme.beat))
            }
            .buttonStyle(.plain)
        }
    }

    private func goalCard(_ g: Goal) -> some View {
        let active = store.activeGoalID == g.id
        let best = store.bestBPM(g)
        let today = store.repsToday(g)
        let data = store.sessions(for: g).filter { $0.countedReps > 0 }.reversed()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                ZStack {
                    Circle().stroke(Theme.stroke, lineWidth: 8)
                    Circle().trim(from: 0, to: store.progress(g))
                        .stroke(LinearGradient(colors: [Theme.beat, Theme.sub], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(store.progress(g) * 100))%").font(.system(.subheadline, design: .rounded).weight(.heavy))
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.name.isEmpty ? "Untitled goal" : g.name).font(.system(.title3, design: .rounded).weight(.heavy))
                    Text("\(g.startBPM) → \(g.targetBPM) BPM").foregroundStyle(Theme.dim)
                }
                Spacer()
                Menu {
                    Button("Edit") { editing = g }
                    Button("Practice current step") { practice(g) }
                    Button("Reset ladder") {
                        if let i = store.goals.firstIndex(where: { $0.id == g.id }) { store.goals[i].passedSteps = 0 }
                    }
                    Button("Delete", role: .destructive) { store.delete(g) }
                } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
                }
            }

            ladderView(g)

            HStack(spacing: 8) {
                stat("Best", "\(best)", "BPM", Theme.down)
                stat("Today", "\(today)/\(g.dailyReps)", "reps", today >= g.dailyReps ? .green : Theme.beat)
                stat("Streak", "\(store.streak(g))", "days", Theme.sub)
            }

            if data.count >= 2 {
                Chart(Array(data)) { s in
                    LineMark(x: .value("Date", s.date), y: .value("BPM", s.bpm))
                        .interpolationMethod(.monotone).foregroundStyle(Theme.beat)
                    PointMark(x: .value("Date", s.date), y: .value("BPM", s.bpm)).foregroundStyle(Theme.beat)
                    RuleMark(y: .value("Target", g.targetBPM))
                        .foregroundStyle(Theme.down.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 140)
            }

            Button { store.activeGoalID = g.id } label: {
                Label(active ? "Active goal" : "Make active", systemImage: active ? "checkmark.circle.fill" : "circle")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(active ? .black : .white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Capsule().fill(active ? Theme.beat : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(active ? Theme.beat.opacity(0.6) : Theme.stroke))
    }

    private func practice(_ g: Goal) {
        store.activeGoalID = g.id
        m.bpm = Double(g.currentBPM)
        m.loopOn = true
        m.reps = g.passReps
        m.syncSnapshot()
    }

    private func ladderView(_ g: Goal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(g.isComplete ? "Ladder complete 🎉" : "Step \(g.passedSteps + 1) of \(g.ladder.count) · \(g.currentBPM) BPM")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                Spacer()
                Text("\(g.passReps) clean reps to pass").font(.caption).foregroundStyle(Theme.dim)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(g.ladder.enumerated()), id: \.offset) { i, bpm in
                        let done = i < g.passedSteps, now = i == g.passedSteps
                        VStack(spacing: 2) {
                            Image(systemName: done ? "checkmark.circle.fill" : (now ? "play.circle.fill" : "lock.fill"))
                                .font(.caption)
                            Text("\(bpm)").font(.system(.subheadline, design: .rounded).weight(.heavy)).monospacedDigit()
                        }
                        .frame(width: 52, height: 52)
                        .foregroundStyle(done ? .black : (now ? .black : Theme.dim))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(done ? Color.green : (now ? Theme.down : Color.white.opacity(0.06))))
                    }
                }
            }
            if !g.isComplete {
                Button { practice(g) } label: {
                    Label("Practice \(g.currentBPM) BPM", systemImage: "play.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(.black).frame(maxWidth: .infinity, minHeight: 42)
                        .background(Capsule().fill(Theme.down))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.dim)
            Text(value).font(.system(.title3, design: .rounded).weight(.heavy)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(unit).font(.caption2).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var history: some View {
        Card(title: "Recent sessions", icon: "clock.arrow.circlepath") {
            ForEach(store.sessions.prefix(15)) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(s.bpm) BPM · \(s.meter)").font(.system(.body, design: .rounded).weight(.semibold))
                        Text(s.date.formatted(date: .abbreviated, time: .shortened)
                             + (store.goals.first { $0.id == s.goalID }.map { " · \($0.name)" } ?? ""))
                            .font(.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(s.cleanReps.map { "\($0)/\(s.reps) clean" } ?? "\(s.reps) reps")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(s.cleanReps == nil ? Theme.beat : .green)
                        if let e = s.avgErrorMs {
                            Text("avg \(Int(e)) ms off" + (s.spreadMs.map { " · ±\(Int($0))" } ?? ""))
                                .font(.caption2).foregroundStyle(Theme.dim)
                        }
                    }
                }
                .contextMenu {
                    Button("Delete", role: .destructive) { store.sessions.removeAll { $0.id == s.id } }
                }
            }
        }
    }
}

// MARK: - Editor

struct GoalEditor: View {
    @State var goal: Goal
    var onSave: (Goal) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal") {
                    TextField("e.g. 16th notes at 120", text: $goal.name)
                }
                Section("Tempo") {
                    Stepper("Starting BPM: \(goal.startBPM)", value: $goal.startBPM, in: 30...280)
                    Stepper("Target BPM: \(goal.targetBPM)", value: $goal.targetBPM, in: 30...280)
                }
                Section {
                    Stepper("Jump per step: +\(goal.stepBPM) BPM", value: $goal.stepBPM, in: 1...40)
                    Stepper("Clean reps to pass: \(goal.passReps)", value: $goal.passReps, in: 1...100)
                    Toggle("Lock metronome to step tempo", isOn: $goal.locked)
                    Text("Steps: " + goal.ladder.map(String.init).joined(separator: " → "))
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Tempo ladder") } footer: {
                    Text("You stay on each tempo until you get the clean reps in one session. Kick check on = only clean kicks count.")
                }
                Section("Daily practice") {
                    Stepper("Reps per day: \(goal.dailyReps)", value: $goal.dailyReps, in: 1...200)
                }
            }
            .navigationTitle(goal.name.isEmpty ? "New goal" : goal.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(goal); dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
