import SwiftUI

// MARK: - Theme

enum Theme {
    static let bgTop = Color(red: 0.07, green: 0.06, blue: 0.16)
    static let bgBottom = Color(red: 0.02, green: 0.02, blue: 0.05)
    static let card = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.10)
    static let down = Color(red: 1.00, green: 0.55, blue: 0.20)   // downbeat
    static let beat = Color(red: 0.30, green: 0.85, blue: 1.00)   // main beats
    static let sub = Color(red: 0.62, green: 0.50, blue: 1.00)    // subdivisions
    static let dim = Color.white.opacity(0.45)

    static func color(_ accent: Int) -> Color { accent == 2 ? down : (accent == 1 ? beat : sub) }
}

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.dim)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.stroke))
    }
}

/// Pill-style selectable chip.
struct Chip: View {
    let text: String
    let selected: Bool
    var tint: Color = Theme.beat
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(.body, design: .rounded).weight(.bold))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
                .foregroundStyle(selected ? .black : .white.opacity(0.85))
                .background(Capsule().fill(selected ? tint : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.2), value: selected)
    }
}

// MARK: - Root with tabs

struct ContentView: View {
    @StateObject private var m = MetronomeEngine()
    @StateObject private var store = GoalStore()
    @State private var startedAt = Date()

    init() {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundColor = UIColor(red: 0.03, green: 0.03, blue: 0.07, alpha: 0.92)
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

    var body: some View {
        TabView {
            MetronomeView(m: m, store: store)
                .tabItem { Label("Metronome", systemImage: "metronome.fill") }
            GoalsView(store: store, m: m)
                .tabItem { Label("Goals", systemImage: "target") }
        }
        .tint(Theme.beat)
        .preferredColorScheme(.dark)
        .onChange(of: m.isPlaying) { _, playing in if playing { startedAt = Date() } }
        .onAppear {
            m.onSessionEnd = { [weak m, weak store] bars, _ in
                guard let m, let store else { return }
                let per = max(m.loopOn ? m.barsPerRep : 1, 1)
                let reps = bars / per
                guard bars > 0 else { return }
                store.log(PracticeSession(
                    goalID: store.activeGoalID,
                    bpm: Int(m.bpm),
                    meter: m.useCustom ? "Custom" : m.signature.label,
                    reps: reps, bars: bars,
                    minutes: Date().timeIntervalSince(startedAt) / 60,
                    cleanReps: m.listenOn ? m.cleanReps : nil,
                    avgErrorMs: m.listenOn ? m.sessionMeanAbs : nil,
                    spreadMs: m.listenOn ? m.sessionSpread : nil))
            }
        }
    }
}

// MARK: - Metronome tab

struct MetronomeView: View {
    @ObservedObject var m: MetronomeEngine
    @ObservedObject var store: GoalStore
    @State private var taps: [Date] = []
    @State private var editingBPM = false
    @State private var bpmText = ""

    private var current: Step? {
        m.pattern.steps.indices.contains(m.currentStep) ? m.pattern.steps[m.currentStep] : nil
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            RadialGradient(colors: [(current.map { Theme.color($0.accent) } ?? Theme.sub).opacity(m.isPlaying ? 0.28 : 0.12), .clear],
                           center: .top, startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.15), value: m.currentStep)

            ScrollView {
                VStack(spacing: 18) {
                    header
                    hero
                    beatStrip
                    kickFeedback
                    tempoCard
                    goalBanner
                    loopCard
                    listenCard
                    meterCard
                    soundCard
                    Color.clear.frame(height: 90)
                }
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)

            VStack { Spacer(); playButton }
        }
        .preferredColorScheme(.dark)
        .onChange(of: m.bpm) { _, _ in m.syncSnapshot() }
        .onChange(of: m.voiceOn) { _, _ in m.syncSnapshot() }
        .onChange(of: m.clickOn) { _, _ in m.syncSnapshot() }
        .onChange(of: m.voiceVolume) { _, _ in m.syncSnapshot() }
        .onChange(of: m.loopOn) { _, _ in m.syncSnapshot() }
        .onChange(of: m.reps) { _, _ in m.syncSnapshot() }
        .onChange(of: m.barsPerRep) { _, _ in m.syncSnapshot() }
        .alert("Enter BPM", isPresented: $editingBPM) {
            TextField("30–280", text: $bpmText).keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Set") {
                if let v = Double(bpmText.filter(\.isNumber)) { m.bpm = min(max(v, 30), 280) }
            }
        } message: { Text("Type a tempo from 30 to 280.") }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spoken").font(.system(size: 30, weight: .heavy, design: .rounded))
                Text("Metronome").font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Theme.beat, Theme.sub], startPoint: .leading, endPoint: .trailing))
            }
            Spacer()
            Text(m.useCustom ? "Custom" : m.signature.label)
                .font(.system(.title2, design: .rounded).weight(.heavy))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.stroke))
        }
        .padding(.top, 8)
    }

    // MARK: Hero — big pulsing count

    private var hero: some View {
        let cd = m.countdownRemaining
        let color = cd != nil ? Theme.down : (current.map { Theme.color($0.accent) } ?? Theme.dim)
        let text = cd.map(String.init) ?? current?.display ?? (m.isReady ? "Ready" : "…")
        return ZStack {
            Circle().stroke(Theme.stroke, lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [Theme.beat, Theme.sub, Theme.down, Theme.beat], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.08), value: progress)
            Circle()
                .fill(RadialGradient(colors: [color.opacity(m.isPlaying ? 0.45 : 0.12), .clear],
                                     center: .center, startRadius: 0, endRadius: 120))
                .padding(26)
            VStack(spacing: 4) {
                Text(text)
                    .font(.system(size: (current == nil && cd == nil) ? 40 : (cd != nil ? 120 : 96), weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .scaleEffect(m.isPlaying && current?.accent ?? 0 > 0 ? 1.08 : 1)
                    .shadow(color: color.opacity(0.6), radius: 18)
                Text(heroCaption)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.dim)
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: m.currentStep)
        }
        .frame(width: 250, height: 250)
        .padding(.vertical, 6)
    }

    private var heroCaption: String {
        if m.countdownRemaining != nil { return "get ready…" }
        guard m.isPlaying else { return m.loopOn ? "\(m.reps) reps ready" : "tap start" }
        if m.loopOn {
            let per = max(m.barsPerRep, 1)
            let rep = min(m.barsDone / per + 1, m.reps)
            return per > 1 ? "rep \(rep)/\(m.reps) · bar \(m.barsDone % per + 1)/\(per)" : "rep \(rep) of \(m.reps)"
        }
        return "bar \(m.barsDone + 1)"
    }

    // MARK: Goal + loop

    @ViewBuilder private var goalBanner: some View {
        if let g = store.activeGoal {
            HStack(spacing: 12) {
                Image(systemName: "target").font(.title3).foregroundStyle(Theme.down)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.name.isEmpty ? "Active goal" : g.name).font(.system(.subheadline, design: .rounded).weight(.bold))
                    Text("Best \(store.bestBPM(g)) → \(g.targetBPM) BPM · today \(store.repsToday(g))/\(g.dailyReps) reps")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                ProgressView(value: store.progress(g)).tint(Theme.down).frame(width: 60)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.down.opacity(0.35)))
        }
    }

    private var loopCard: some View {
        Card(title: "Loop", icon: "repeat") {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(Theme.dim)
                Text("Count-down").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                Spacer(minLength: 4)
                ForEach([0, 3, 5, 10], id: \.self) { sec in
                    Chip(text: sec == 0 ? "Off" : "\(sec)s", selected: m.countdownSeconds == sec, tint: Theme.down) {
                        m.countdownSeconds = sec
                    }
                }
            }
            HStack(spacing: 10) {
                Button { m.loopOn.toggle() } label: {
                    Label(m.loopOn ? "Loop on" : "Loop off", systemImage: m.loopOn ? "repeat.circle.fill" : "repeat")
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .foregroundStyle(m.loopOn ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(m.loopOn ? Theme.down : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(m.isPlaying)
            }
            if m.loopOn {
                counter("Reps", value: $m.reps, range: 1...200, quick: [5, 10, 20, 50])
                counter("Bars per rep", value: $m.barsPerRep, range: 1...16, quick: [1, 2, 4, 8])
                Text("Plays \(m.reps * m.barsPerRep) bars, then stops and logs the session\(store.activeGoal == nil ? "" : " to your goal").")
                    .font(.footnote).foregroundStyle(Theme.dim)
            } else {
                Text("Turn on to play a set number of reps, then stop automatically.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }

    private func counter(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, quick: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                Spacer()
                round("−") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 1) }
                Text("\(value.wrappedValue)")
                    .font(.system(.title2, design: .rounded).weight(.heavy)).monospacedDigit()
                    .frame(minWidth: 48)
                round("+") { value.wrappedValue = min(range.upperBound, value.wrappedValue + 1) }
            }
            HStack(spacing: 8) {
                ForEach(quick, id: \.self) { q in
                    Chip(text: "\(q)", selected: value.wrappedValue == q, tint: Theme.down) { value.wrappedValue = q }
                }
            }
        }
    }

    private var progress: CGFloat {
        let n = m.pattern.steps.count
        guard n > 0, m.currentStep >= 0 else { return 0 }
        return CGFloat(m.currentStep + 1) / CGFloat(n)
    }

    // MARK: Beat strip — every step, grouped by beat

    private var beatStrip: some View {
        let steps = m.pattern.steps
        let beats = Dictionary(grouping: steps.indices, by: { steps[$0].beat }).sorted { $0.key < $1.key }
        let cols = [GridItem(.adaptive(minimum: steps.count > 24 ? 64 : 76), spacing: 8)]
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(beats, id: \.key) { _, idxs in
                HStack(spacing: 3) {
                    ForEach(idxs, id: \.self) { i in
                        let s = steps[i]
                        let on = i == m.currentStep
                        Text(s.display)
                            .font(.system(size: s.accent > 0 ? 17 : 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(on ? .black : (s.accent > 0 ? .white : Theme.dim))
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(on ? Theme.color(s.accent) : Color.white.opacity(s.accent > 0 ? 0.10 : 0.05))
                                    .shadow(color: on ? Theme.color(s.accent).opacity(0.8) : .clear, radius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(markColor(i), lineWidth: 2.5)
                            )
                            .overlay(alignment: .bottom) {
                                if m.listenOn && isKick(i, s) {
                                    Circle().fill(Theme.down).frame(width: 5, height: 5).padding(.bottom, 3)
                                }
                            }
                            .scaleEffect(on ? 1.08 : 1)
                            .animation(.easeOut(duration: 0.08), value: on)
                            .onTapGesture {
                                if m.listenOn && m.kickTarget == .pattern { m.toggleKickStep(i) }
                            }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            }
        }
    }

    private func isKick(_ i: Int, _ s: Step) -> Bool {
        switch m.kickTarget {
        case .everyBeat: return s.word.map { Counting.numbers.contains($0) } ?? false
        case .everyCount: return s.word != nil
        case .pattern: return m.kickSteps.contains(i)
        }
    }

    private func markColor(_ i: Int) -> Color {
        guard m.listenOn, let mk = m.marks[i] else { return .clear }
        switch mk {
        case .miss: return .red
        case .hit(let ms):
            if abs(ms) <= m.toleranceMs { return .green }
            return abs(ms) <= m.toleranceMs * 2 ? .yellow : .red
        }
    }

    // MARK: Kick feedback + listen settings

    @ViewBuilder private var kickFeedback: some View {
        if m.listenOn {
            HStack(spacing: 8) {
                fb("Last kick", m.lastHit.map(hitText) ?? "—",
                   m.lastHit.map { abs($0) <= m.toleranceMs ? Color.green : .yellow } ?? Theme.dim)
                if let r = m.repResults.last {
                    fb("Last rep", r.clean ? "Clean ✓" : (r.misses > 0 ? "\(r.misses) missed" : "Off \(Int(r.meanAbs)) ms"),
                       r.clean ? .green : .red)
                } else {
                    fb("Last rep", "—", Theme.dim)
                }
                fb("Clean reps", "\(m.cleanReps)/\(m.repResults.count)", Theme.beat)
            }
            if let r = m.repResults.last, r.hits > 0 {
                Text(tendency(r)).font(.footnote).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hitText(_ ms: Double) -> String {
        abs(ms) < 3 ? "On it" : "\(Int(abs(ms).rounded())) ms \(ms > 0 ? "late" : "early")"
    }

    private func tendency(_ r: RepResult) -> String {
        let lean = abs(r.mean) < 5 ? "centered on the beat" : "\(Int(abs(r.mean))) ms \(r.mean > 0 ? "behind (dragging)" : "ahead (rushing)")"
        return "Rep \(r.rep + 1): \(r.hits) kicks, \(lean), spread ±\(Int(r.spread)) ms."
    }

    private func fb(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Theme.dim)
            Text(value).font(.system(.headline, design: .rounded).weight(.heavy)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private var listenCard: some View {
        Card(title: "Kick check", icon: "mic.fill") {
            Button {
                if m.listenOn { m.listenOn = false; m.syncSnapshot() }
                else { m.requestMic { ok in if ok { m.listenOn = true; m.syncSnapshot() } } }
            } label: {
                Label(m.listenOn ? "Listening for kicks" : "Listen for kicks",
                      systemImage: m.listenOn ? "waveform.circle.fill" : "mic")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundStyle(m.listenOn ? .black : .white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(m.listenOn ? Color.green : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(m.isPlaying)

            if m.micDenied {
                Text("Microphone access is off. Turn it on in Settings → Privacy & Security → Microphone.")
                    .font(.footnote).foregroundStyle(.red)
            }

            if m.listenOn {
                Text("Kick should hit").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                HStack(spacing: 8) {
                    ForEach(KickTarget.allCases) { t in
                        Chip(text: t.rawValue, selected: m.kickTarget == t, tint: Theme.down) {
                            m.kickTarget = t; m.syncSnapshot()
                        }
                    }
                }
                if m.kickTarget == .pattern {
                    Text(m.kickSteps.isEmpty ? "Tap the tiles in the beat strip to mark where your kicks go."
                                             : "\(m.kickSteps.count) kicks marked — tap tiles to change.")
                        .font(.footnote).foregroundStyle(Theme.down)
                }

                Text("Clean if within").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach([10.0, 20, 30, 50, 75, 100, 150, 200], id: \.self) { t in
                            Chip(text: "±\(Int(t)) ms", selected: m.toleranceMs == t, tint: Theme.sub) { m.toleranceMs = t }
                        }
                    }
                }
                HStack {
                    round("−") { m.toleranceMs = max(5, m.toleranceMs - 5) }
                    Slider(value: $m.toleranceMs, in: 5...250, step: 5).tint(Theme.sub)
                    round("+") { m.toleranceMs = min(250, m.toleranceMs + 5) }
                    Text("±\(Int(m.toleranceMs)) ms").font(.system(.subheadline, design: .rounded).weight(.bold))
                        .monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                }

                HStack {
                    Text("Mic").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                    GeometryReader { g in
                        Capsule().fill(Color.white.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * CGFloat(m.isPlaying ? m.micLevel : 0))
                            }
                    }
                    .frame(height: 8)
                }
                HStack {
                    Text("Sensitivity").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
                    Slider(value: $m.sensitivity, in: 0...1).tint(Theme.down)
                }

                HStack(spacing: 10) {
                    Button { m.calibrate() } label: {
                        Label(m.calibrating ? "Kick along… (12 hits)" : "Calibrate", systemImage: "scope")
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Capsule().fill(m.calibrating ? Theme.down.opacity(0.35) : Theme.card))
                            .overlay(Capsule().stroke(Theme.stroke))
                    }
                    .buttonStyle(.plain)
                    .disabled(!m.isPlaying || m.calibrating)
                    Text("Offset \(Int(m.calibrationMs)) ms").font(.footnote.monospacedDigit()).foregroundStyle(Theme.dim)
                    Button("Reset") { m.calibrationMs = 0; UserDefaults.standard.set(0.0, forKey: "kickCalibrationMs") }
                        .font(.footnote.weight(.bold)).tint(Theme.beat)
                }
                Text("Use headphones so the mic doesn't hear the click. To calibrate: press Start, tap Calibrate, then kick steadily along with the beat. Redo it if you switch headphones.")
                    .font(.footnote).foregroundStyle(Theme.dim)
            }
        }
    }

    // MARK: Tempo

    private var tempoMarking: String {
        switch m.bpm {
        case ..<60: "Largo"
        case ..<76: "Adagio"
        case ..<108: "Andante"
        case ..<120: "Moderato"
        case ..<168: "Allegro"
        case ..<200: "Presto"
        default: "Prestissimo"
        }
    }

    private var tempoCard: some View {
        Card(title: "Tempo", icon: "metronome") {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    bpmText = "\(Int(m.bpm))"
                    editingBPM = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(Int(m.bpm))")
                            .font(.system(size: 60, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("BPM").font(.headline).foregroundStyle(Theme.dim)
                        Image(systemName: "pencil.circle.fill").font(.title3).foregroundStyle(Theme.beat)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tempoMarking).font(.system(.headline, design: .serif).italic())
                    Text(m.useCustom || m.signature.unit == 4 ? "♩ = 1 beat" : "♪ = 1 beat")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
            }
            Slider(value: $m.bpm, in: 30...280, step: 1).tint(Theme.beat)
            HStack(spacing: 8) {
                round("−5") { m.nudge(-5) }
                round("−1") { m.nudge(-1) }
                Button { tap() } label: {
                    Label("Tap", systemImage: "hand.tap.fill")
                        .font(.system(.body, design: .rounded).weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.black)
                        .background(Capsule().fill(Theme.sub))
                }
                .buttonStyle(.plain)
                round("+1") { m.nudge(1) }
                round("+5") { m.nudge(5) }
            }
        }
    }

    private func round(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .frame(width: 46, height: 44)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func tap() {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 2.5 } + [now]
        guard taps.count >= 2 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        m.bpm = min(max((60 / (gaps.reduce(0, +) / Double(gaps.count))).rounded(), 30), 280)
    }

    // MARK: Meter

    private var meterCard: some View {
        Card(title: "Rhythm", icon: "music.quarternote.3") {
            HStack(spacing: 8) {
                Chip(text: "Time signature", selected: !m.useCustom) { m.useCustom = false }
                Chip(text: "Custom bar", selected: m.useCustom, tint: Theme.down) { m.useCustom = true }
            }
            if m.useCustom { customSection } else { standardSection }
        }
    }

    private var standardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TimeSignature.all) { sig in
                        Chip(text: sig.label, selected: sig == m.signature) { m.signature = sig }
                    }
                }
            }
            Text("Speak the count in").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.dim)
            HStack(spacing: 8) {
                ForEach(Subdivision.allCases) { sub in
                    Chip(text: noteName(sub), selected: m.subdivision == sub, tint: Theme.sub) { m.subdivision = sub }
                }
            }
            Text(hint).font(.footnote).foregroundStyle(Theme.dim)
        }
    }

    private func noteName(_ s: Subdivision) -> String {
        switch s { case .quarter: "♩ 4th"; case .eighth: "♫ 8th"; case .sixteenth: "♬ 16th" }
    }

    private var hint: String {
        let n = m.signature.beats
        switch m.subdivision {
        case .quarter: return "Speaks every beat: “1 2 3 … \(n)”."
        case .eighth: return "Speaks every 8th: “1 and 2 and … \(n) and”."
        case .sixteenth: return "Speaks every 16th: “1 e and a 2 e and a …”."
        }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick the notes for each beat — up to 12 beats.")
                .font(.footnote).foregroundStyle(Theme.dim)
            ForEach(m.customBeats.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(i == 0 ? Theme.down : Theme.beat))
                        .foregroundStyle(.black)
                    ForEach(Subdivision.allCases) { sub in
                        Chip(text: noteName(sub), selected: m.customBeats.indices.contains(i) && m.customBeats[i] == sub,
                             tint: Theme.sub) {
                            if m.customBeats.indices.contains(i) { m.customBeats[i] = sub }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                pill("Remove", "minus", enabled: m.customBeats.count > 1) { m.customBeats.removeLast() }
                pill("Add beat", "plus", enabled: m.customBeats.count < 12) { m.customBeats.append(.quarter) }
            }
        }
    }

    private func pill(_ t: String, _ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Capsule().stroke(Theme.stroke).background(Capsule().fill(Theme.card)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: Sound

    private var soundCard: some View {
        Card(title: "Sound", icon: "speaker.wave.2.fill") {
            HStack(spacing: 8) {
                Chip(text: "🗣 Voice", selected: m.voiceOn, tint: Theme.beat) { m.voiceOn.toggle() }
                Chip(text: "Click", selected: m.clickOn, tint: Theme.down) { m.clickOn.toggle() }
            }
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(Theme.dim)
                Slider(value: $m.voiceVolume, in: 0...1).tint(Theme.beat)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Theme.dim)
            }
            .disabled(!m.voiceOn)
            .opacity(m.voiceOn ? 1 : 0.4)
        }
    }

    // MARK: Play

    private var playButton: some View {
        Button { m.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: (m.isPlaying || m.countdownRemaining != nil) ? "stop.fill" : "play.fill")
                Text(!m.isReady ? "Loading voice…"
                     : m.countdownRemaining.map { "Cancel (\($0))" }
                     ?? (m.isPlaying ? "Stop" : (m.countdownSeconds > 0 ? "Start in \(m.countdownSeconds)s" : "Start")))
            }
            .font(.system(.title3, design: .rounded).weight(.heavy))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                Capsule().fill(m.isPlaying || m.countdownRemaining != nil
                    ? LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.4), Theme.down], startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Theme.beat, Theme.sub], startPoint: .leading, endPoint: .trailing))
            )
            .shadow(color: (m.isPlaying ? Theme.down : Theme.beat).opacity(0.5), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(!m.isReady)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

#Preview { ContentView() }
