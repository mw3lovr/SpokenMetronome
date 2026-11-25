import SwiftUI

struct ContentView: View {
    @StateObject private var m = MetronomeEngine()
    @State private var taps: [Date] = []
    @State private var editingBPM = false
    @State private var bpmText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    beatGrid
                    tempoSection
                    meterSection
                    soundSection
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { playButton }
            .navigationTitle("Spoken Metronome")
            .onChange(of: m.bpm) { _, _ in m.syncSnapshot() }
            .onChange(of: m.voiceOn) { _, _ in m.syncSnapshot() }
            .onChange(of: m.clickOn) { _, _ in m.syncSnapshot() }
            .onChange(of: m.voiceVolume) { _, _ in m.syncSnapshot() }
        }
    }

    // MARK: Beat display

    private var beatGrid: some View {
        let steps = m.pattern.steps
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6),
                         count: min(steps.count, m.subdivision == .sixteenth ? 8 : 6))
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(steps.indices, id: \.self) { i in
                let s = steps[i]
                let on = i == m.currentStep
                Text(s.display)
                    .font(.system(size: s.accent > 0 ? 22 : 17, weight: s.accent > 0 ? .bold : .medium, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(on ? (s.accent == 2 ? Color.orange : Color.accentColor)
                                     : Color(.secondarySystemBackground))
                    )
                    .foregroundStyle(on ? .white : (s.accent > 0 ? .primary : .secondary))
                    .animation(.easeOut(duration: 0.06), value: on)
            }
        }
    }

    // MARK: Tempo

    private var tempoSection: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button {
                    bpmText = "\(Int(m.bpm))"
                    editingBPM = true
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(m.bpm))").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                        Image(systemName: "pencil").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .alert("Enter BPM", isPresented: $editingBPM) {
                    TextField("30–280", text: $bpmText).keyboardType(.numberPad)
                    Button("Cancel", role: .cancel) {}
                    Button("Set") {
                        if let v = Double(bpmText.filter(\.isNumber)) { m.bpm = min(max(v, 30), 280) }
                    }
                } message: { Text("Type a tempo from 30 to 280.") }
                Text("BPM").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text(m.useCustom || m.signature.unit == 4 ? "♩ = beat" : "♪ = beat")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: $m.bpm, in: 30...280, step: 1)
            HStack {
                stepper("−5") { m.nudge(-5) }
                stepper("−1") { m.nudge(-1) }
                Button("Tap") { tap() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                stepper("+1") { m.nudge(1) }
                stepper("+5") { m.nudge(5) }
            }
        }
    }

    private func stepper(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action).buttonStyle(.bordered).monospacedDigit()
    }

    private func tap() {
        let now = Date()
        taps = taps.filter { now.timeIntervalSince($0) < 2.5 } + [now]
        guard taps.count >= 2 else { return }
        let gaps = zip(taps.dropFirst(), taps).map { $0.timeIntervalSince($1) }
        m.bpm = min(max((60 / (gaps.reduce(0, +) / Double(gaps.count))).rounded(), 30), 280)
    }

    // MARK: Meter

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Bar", selection: $m.useCustom) {
                Text("Time signature").tag(false)
                Text("Custom bar").tag(true)
            }
            .pickerStyle(.segmented)
            if m.useCustom { customSection } else { standardSection }
        }
    }

    private var standardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(TimeSignature.all) { sig in
                        Button { m.signature = sig } label: {
                            Text(sig.label).font(.system(.title3, design: .rounded).bold())
                                .frame(minWidth: 52, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(sig == m.signature ? .accentColor : Color(.systemGray4))
                        .foregroundStyle(sig == m.signature ? .white : .primary)
                    }
                }
            }
            Text("Speak the count in").font(.headline)
            Picker("Subdivision", selection: $m.subdivision) {
                ForEach(Subdivision.allCases) { Text("\($0.rawValue) notes").tag($0) }
            }
            .pickerStyle(.segmented)
            Text(hint).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func noteName(_ s: Subdivision) -> String {
        switch s { case .quarter: "♩ 4th"; case .eighth: "♫ 8ths"; case .sixteenth: "𝅘𝅥𝅯 16ths" }
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick the notes for each beat of your bar (up to 12 beats).")
                .font(.footnote).foregroundStyle(.secondary)
            ForEach(m.customBeats.indices, id: \.self) { i in
                HStack {
                    Text("Beat \(i + 1)").font(.headline).frame(width: 70, alignment: .leading)
                    Picker("Beat \(i + 1)", selection: Binding(
                        get: { m.customBeats[min(i, m.customBeats.count - 1)] },
                        set: { if i < m.customBeats.count { m.customBeats[i] = $0 } })) {
                        ForEach(Subdivision.allCases) { Text(noteName($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            HStack {
                Button {
                    if m.customBeats.count > 1 { m.customBeats.removeLast() }
                } label: { Label("Remove beat", systemImage: "minus") }
                .disabled(m.customBeats.count <= 1)
                Spacer()
                Button {
                    if m.customBeats.count < 12 { m.customBeats.append(.quarter) }
                } label: { Label("Add beat", systemImage: "plus") }
                .disabled(m.customBeats.count >= 12)
            }
            .buttonStyle(.bordered)
        }
    }

    private var hint: String {
        let n = m.signature.beats
        switch m.subdivision {
        case .quarter: return "Speaks every beat: “1 2 3 … \(n)”."
        case .eighth: return "Speaks every 8th: “1 and 2 and … \(n) and”."
        case .sixteenth: return "Speaks every 16th: “1 e and a 2 e and a …”."
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        VStack(spacing: 4) {
            Toggle("Speak the count", isOn: $m.voiceOn)
            Toggle("Click", isOn: $m.clickOn)
            HStack {
                Image(systemName: "speaker.wave.1")
                Slider(value: $m.voiceVolume, in: 0...1)
                Image(systemName: "speaker.wave.3")
            }
            .disabled(!m.voiceOn)
        }
    }

    private var playButton: some View {
        Button { m.toggle() } label: {
            Label(m.isReady ? (m.isPlaying ? "Stop" : "Start") : "Loading voice…",
                  systemImage: m.isPlaying ? "stop.fill" : "play.fill")
                .font(.title2.bold())
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(m.isPlaying ? .red : .accentColor)
        .disabled(!m.isReady)
        .padding(.horizontal).padding(.bottom, 8)
        .background(.bar)
    }
}

#Preview { ContentView() }
