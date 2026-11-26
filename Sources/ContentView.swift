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

// MARK: - Main view

struct ContentView: View {
    @StateObject private var m = MetronomeEngine()
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
                    tempoCard
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
        let color = current.map { Theme.color($0.accent) } ?? Theme.dim
        let text = current?.display ?? (m.isReady ? "Ready" : "…")
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
                    .font(.system(size: current == nil ? 40 : 96, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                    .scaleEffect(m.isPlaying && current?.accent ?? 0 > 0 ? 1.08 : 1)
                    .shadow(color: color.opacity(0.6), radius: 18)
                Text(current.map { "beat \($0.beat + 1)" } ?? "tap play")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.dim)
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.55), value: m.currentStep)
        }
        .frame(width: 250, height: 250)
        .padding(.vertical, 6)
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
                            .scaleEffect(on ? 1.08 : 1)
                            .animation(.easeOut(duration: 0.08), value: on)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
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
                Image(systemName: m.isPlaying ? "stop.fill" : "play.fill")
                Text(m.isReady ? (m.isPlaying ? "Stop" : "Start") : "Loading voice…")
            }
            .font(.system(.title3, design: .rounded).weight(.heavy))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                Capsule().fill(m.isPlaying
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
