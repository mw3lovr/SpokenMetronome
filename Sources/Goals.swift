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

    func delete(_ g: Goal) {
        goals.removeAll { $0.id == g.id }
        sessions.removeAll { $0.goalID == g.id }
        if activeGoalID == g.id { activeGoalID = goals.first?.id }
    }

    func sessions(for g: Goal) -> [PracticeSession] { sessions.filter { $0.goalID == g.id } }

    func bestBPM(_ g: Goal) -> Int { sessions(for: g).filter { $0.reps > 0 }.map(\.bpm).max() ?? g.startBPM }

    func progress(_ g: Goal) -> Double {
        let span = Double(g.targetBPM - g.startBPM)
        guard span > 0 else { return bestBPM(g) >= g.targetBPM ? 1 : 0 }
        return min(max(Double(bestBPM(g) - g.startBPM) / span, 0), 1)
    }

    func repsToday(_ g: Goal) -> Int {
        sessions(for: g).filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.reps }
    }

    /// Consecutive days (ending today or yesterday) with at least one rep.
    func streak(_ g: Goal) -> Int {
        let cal = Calendar.current
        let days = Set(sessions(for: g).filter { $0.reps > 0 }.map { cal.startOfDay(for: $0.date) })
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
        let data = store.sessions(for: g).filter { $0.reps > 0 }.reversed()
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
                    Button("Practice this goal") { store.activeGoalID = g.id; m.bpm = Double(best) }
                    Button("Delete", role: .destructive) { store.delete(g) }
                } label: {
                    Image(systemName: "ellipsis").font(.title3).frame(width: 44, height: 44)
                }
            }

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
                    Text("\(s.reps) reps").font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(Theme.beat)
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
