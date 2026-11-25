import SwiftUI

struct ContentView: View {
    @StateObject private var m = MetronomeEngine()
    @State private var taps: [Date] = []

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
                Text("\(Int(m.bpm))").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                Text("BPM").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text(m.signature.unit == 4 ? "♩ = beat" : "♪ = beat")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Slider(value: $m.bpm, in: 30...280, step: 1)
            HStack {
                stepper("−5") { m.bpm -= 5 }
                stepper("−1") { m.bpm -= 1 }
                Button("Tap") { tap() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity)
                stepper("+1") { m.bpm += 1 }
                stepper("+5") { m.bpm += 5 }
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
        m.bpm = (60 / (gaps.reduce(0, +) / Double(gaps.count))).rounded()
    }

    // MARK: Meter

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time signature").font(.headline)
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

    private var hint: String {
        if m.signature.unit == 4 {
            switch m.subdivision {
            case .quarter: return "Counts “1 2 3 4”."
            case .eighth: return "Counts “1 and 2 and…”."
            case .sixteenth: return "Counts “1 e and a 2 e and a…”."
            }
        }
        let g = m.signature.groups.map(String.init).joined(separator: "+")
        switch m.subdivision {
        case .quarter: return "Speaks the main pulses (grouped \(g)); clicks every eighth."
        case .eighth: return "Counts every eighth note, grouped \(g)."
        case .sixteenth: return "Counts “1 and 2 and…” on every sixteenth."
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
