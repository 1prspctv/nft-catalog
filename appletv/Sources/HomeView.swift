import SwiftUI

struct Show: Identifiable {
    let id = UUID()
    let pieces: [Piece]
    let settings: SlideshowSettings
}

struct HomeView: View {
    @EnvironmentObject var store: CatalogStore
    @AppStorage("secondsPerImage") private var secondsPerImage = 15.0
    @AppStorage("shuffle") private var shuffle = false
    @AppStorage("showTitles") private var showTitles = true
    @AppStorage("videoSound") private var videoSound = false

    @State private var show: Show?
    @State private var askNumber = false
    @State private var numberText = ""
    @State private var numberError = ""
    @State private var lookingUp = false
    @State private var showSettings = false
    @FocusState private var focus: HomeFocus?
    private enum HomeFocus { case play, number }

    private var settings: SlideshowSettings {
        SlideshowSettings(secondsPerImage: secondsPerImage, shuffle: shuffle, showTitles: showTitles, videoSound: videoSound)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 44) {
                    header
                    HStack(spacing: 30) {
                        Button { play(store.pieces) } label: { Label("Play everything", systemImage: "play.fill") }
                            .disabled(store.pieces.isEmpty)
                            .focused($focus, equals: .play)
                        Button { play(store.pieces.filter { $0.kind == .video }) } label: { Label("Videos only", systemImage: "film") }
                            .disabled(store.pieces.isEmpty)
                        Button { askNumber = true; numberError = "" } label: { Label("Enter set number", systemImage: "number") }
                            .focused($focus, equals: .number)
                        Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                    .defaultFocus($focus, .play)
                    // On a first launch the play buttons wait for the collection; move to Play once it's there.
                    .onChange(of: store.pieces.isEmpty) { _, empty in
                        if !empty && focus == .number && !askNumber { focus = .play }
                    }
                    setsSection
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .alert("Enter set number", isPresented: $askNumber) {
                TextField("Set number", text: $numberText).keyboardType(.numberPad)
                Button("Play") { Task { await openNumber() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The number is shown in the catalog after you send a set to Apple TV.")
            }
            .task { await demoIfAsked() }
            .fullScreenCover(item: $show) { s in
                SlideshowView(pieces: s.pieces, settings: s.settings, store: store) { show = nil }
                    .ignoresSafeArea()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(Catalog.accountName) collection").font(.largeTitle).bold()
            if !store.status.isEmpty {
                Text(store.status).foregroundStyle(.secondary)
            } else if !store.pieces.isEmpty {
                Text("\(store.pieces.count) pieces").foregroundStyle(.secondary)
            }
            if !numberError.isEmpty { Text(numberError).foregroundStyle(.orange) }
            if lookingUp { ProgressView() }
        }
    }

    private var setsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("Sets from the catalog").font(.title2).bold()
                Spacer()
                Button { Task { await store.refreshSets() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            if !store.setsMessage.isEmpty { Text(store.setsMessage).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380, maximum: 420), spacing: 48)], alignment: .leading, spacing: 60) {
                ForEach(store.sets) { set in
                    Button { play(set) } label: { SetCard(set: set) }
                        .buttonStyle(.card)
                }
            }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Picker("Time per image", selection: $secondsPerImage) {
                    ForEach([5.0, 10, 15, 30, 60, 120, 300], id: \.self) { s in
                        Text(s < 60 ? "\(Int(s)) seconds" : "\(Int(s / 60)) minute\(s == 60 ? "" : "s")").tag(s)
                    }
                }
                Toggle("Shuffle", isOn: $shuffle)
                Toggle("Show titles", isOn: $showTitles)
                Toggle("Video sound", isOn: $videoSound)
                Section {
                    Text("Short videos loop until the time per image is up. Longer videos play to the end.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func play(_ pieces: [Piece]) {
        guard !pieces.isEmpty else { return }
        show = Show(pieces: pieces, settings: settings)
    }

    private func play(_ set: PieceSet) {
        let list = set.keys.compactMap { store.piece(for: $0) }
        if list.isEmpty {
            numberError = "None of the pieces in “\(set.title)” are in the collection now."
            return
        }
        numberError = list.count < set.keys.count
            ? "\(set.keys.count - list.count) pieces in “\(set.title)” aren't in the collection any more, so they're skipped." : ""
        play(list)
    }

    /// For automated previews on a simulator: launch with -demoPlay or -demoSet <number>.
    private func demoIfAsked() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-demoPlay") || args.contains("-demoSet") else { return }
        for _ in 0..<120 where store.pieces.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000) }
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if let i = args.firstIndex(of: "-demoSet"), i + 1 < args.count, let n = Int(args[i + 1]) {
            numberText = String(n); await openNumber()
        } else {
            play(Array(store.pieces.suffix(12)))
        }
    }

    private func openNumber() async {
        let digits = numberText.filter(\.isNumber)
        numberText = ""
        guard let n = Int(digits) else { numberError = "Type the set's number, for example 12."; return }
        lookingUp = true
        defer { lookingUp = false }
        switch await store.fetchSet(number: n) {
        case .success(let s): play(s)
        case .failure(let e): numberError = e.message
        }
    }
}

struct SetCard: View {
    @EnvironmentObject var store: CatalogStore
    let set: PieceSet

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color(white: 0.12)
                if let first = set.keys.lazy.compactMap({ store.piece(for: $0) }).first,
                   let url = Catalog.urls(for: first.thumbURI).first {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color(white: 0.12) }
                }
            }
            .frame(width: 400, height: 225)
            .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(set.title).font(.headline).lineLimit(1)
                Text("Set \(set.number) · \(set.keys.count) pieces").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 400, alignment: .leading)
        }
    }
}
