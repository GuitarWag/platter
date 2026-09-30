import SwiftUI

/// The library browser under the decks: a toolbar (search, Auto DJ, add playlist), the album
/// list, the track table, and the Auto DJ queue while it runs.
struct LibraryBrowser: View {
    let model: AppModel
    @ObservedObject private var library: Library
    @ObservedObject private var auto: AutoDJ
    @ObservedObject private var deckA: DeckState
    @ObservedObject private var deckB: DeckState

    @State private var playlistURL = ""
    @State private var renaming: Album?
    @State private var nameDraft = ""
    @State private var editing: Track?
    @State private var titleDraft = ""
    @State private var artistDraft = ""
    @State private var deleting: Album?
    @State private var renamingSmart: SmartAlbum?
    @State private var savingSmart = false
    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        self.model = model
        library = model.library
        auto = model.autoDJ
        deckA = model.deckA
        deckB = model.deckB
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let e = library.error {
                InlineError(message: e) { library.error = nil }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider().overlay(Color.black)
            HStack(spacing: 0) {
                albumsPane.frame(width: 230)
                Divider().overlay(Color.black)
                tracksPane
                if auto.phase != .idle {
                    Divider().overlay(Color.black)
                    QueuePanel(auto: auto).frame(width: 270)
                }
            }
        }
        .background(Theme.panel)
        .background {
            // Cmd-F focuses search, anywhere in the window.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .alert("Rename album", isPresented: isPresent($renaming)) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { if let a = renaming { library.rename(a, to: nameDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit track", isPresented: isPresent($editing)) {
            TextField("Title", text: $titleDraft)
            TextField("Artist", text: $artistDraft)
            Button("Save") { if let t = editing { library.edit(t, title: titleDraft, artist: artistDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename smart album", isPresented: isPresent($renamingSmart)) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { if let a = renamingSmart { library.rename(a, to: nameDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Save filter as smart album", isPresented: $savingSmart) {
            TextField("Name", text: $nameDraft)
            Button("Save") { library.saveFilterAsSmartAlbum(named: nameDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A smart album lists every track in the library that matches the filter.")
        }
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: isPresent($deleting)) {
            Button("Delete album", role: .destructive) { if let a = deleting { library.delete(a) } }
        } message: {
            Text("The tracks and their downloads stay in the library. Search still finds them.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.textDim)
                TextField("Search tracks, artists, albums  ⌘F", text: $library.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onExitCommand { library.searchText = "" }
                if library.isSearching {
                    Button { library.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
            .frame(width: 300)

            AutoDJBar(auto: auto, start: startAutoDJ)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if library.isResolving { ProgressView().controlSize(.small) }
                TextField(YTDLP.isInstalled() ? "Paste a YouTube playlist URL" : "yt-dlp not found: brew install yt-dlp ffmpeg",
                          text: $playlistURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 280)
                    .onSubmit(addPlaylist)
                    .disabled(!YTDLP.isInstalled())
                Button("Add Album", action: addPlaylist)
                    .controlSize(.small)
                    .disabled(playlistURL.trimmed.isEmpty || library.isResolving || !YTDLP.isInstalled())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func startAutoDJ() {
        let list = library.visibleTracks
        if list.isEmpty {
            library.error = "Select an album with tracks first."
        } else {
            auto.start(tracks: list)
        }
    }

    private func addPlaylist() {
        let url = playlistURL.trimmed
        guard !url.isEmpty else { return }
        playlistURL = ""
        Task { await library.addPlaylist(url: url) }
    }

    // MARK: Albums

    /// Albums whose name matches the search, plus albums that contain a matching track.
    private var visibleAlbums: [Album] {
        guard library.isSearching else { return library.albums }
        let q = library.searchText.trimmed
        let hitNames = Set(library.searchResults.flatMap { $0.albumNames.components(separatedBy: ", ") })
        return library.albums.filter { $0.name.localizedStandardContains(q) || hitNames.contains($0.name) }
    }

    private var albumsPane: some View {
        List(selection: $library.source) {
            Section {
                Label("All Tracks", systemImage: "music.note").tag(Source.all)
                Label("History", systemImage: "clock.arrow.circlepath").tag(Source.history)
            } header: {
                PanelLabel("LIBRARY")
            }
            if !library.smartAlbums.isEmpty {
                Section {
                    ForEach(library.smartAlbums) { smart in
                        Label(smart.name, systemImage: "gearshape")
                            .lineLimit(1)
                            .tag(Source.smart(smart.id))
                            .contextMenu {
                                Button("Rename…") { nameDraft = smart.name; renamingSmart = smart }
                                Button("Delete smart album", role: .destructive) { library.delete(smart) }
                            }
                    }
                } header: {
                    PanelLabel("SMART ALBUMS")
                }
            }
            Section {
                ForEach(visibleAlbums) { album in
                    AlbumRow(album: album)
                        .tag(Source.album(album.id))
                        .contextMenu { albumMenu(album) }
                }
                .onMove(perform: library.isSearching ? nil : moveAlbums)
            } header: {
                HStack {
                    PanelLabel("ALBUMS")
                    Spacer()
                    Button { library.createAlbum(named: "New Album") } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .foregroundColor(Theme.textDim)
                        .help("New empty album")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .font(.system(size: 12))
    }

    private var moveAlbums: (IndexSet, Int) -> Void { { library.moveAlbums(from: $0, to: $1) } }
    private var moveTracks: (IndexSet, Int) -> Void { { library.moveTracks(from: $0, to: $1) } }

    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        Button("Rename…") { nameDraft = album.name; renaming = album }
        if album.sourceURL != nil {
            Button("Check playlist for new tracks") { Task { await library.refresh(album) } }
        }
        Button("Download all tracks") { Task { await library.downloadAll(album) } }
        if let url = album.sourceURL {
            Button("Copy playlist URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
        }
        Divider()
        Button("Delete album…", role: .destructive) { deleting = album }
    }

    // MARK: Tracks

    private var tracksPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            tracksHeader
                .padding(.horizontal, 12)
                .padding(.top, 6)
            FilterBar(library: library, deckA: deckA, deckB: deckB) {
                nameDraft = "Smart Album"
                savingSmart = true
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            ColumnHeader(extraColumn: extraColumn, sort: $library.sort)
                .padding(.horizontal, 12)
            Divider().overlay(Theme.line)
            List {
                ForEach(Array(library.visibleTracks.enumerated()), id: \.offset) { i, track in
                    TrackRow(number: i + 1,
                             track: track,
                             activity: library.activity[track.id],
                             extraColumn: extraColumn != nil,
                             onDecks: [deckA, deckB].filter { $0.track?.id == track.id }.map(\.deck),
                             mixesWith: mixKey,
                             load: { model.load(track, onto: $0) })
                        .contextMenu { trackMenu(track) }
                        .onTapGesture(count: 2) { model.loadOnFreeDeck(track) }
                }
                .onMove(perform: library.canReorder ? moveTracks : nil)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if library.visibleTracks.isEmpty { Text(emptyText).font(.system(size: 11)).foregroundColor(Theme.textDim) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { $0.isFileURL }
            guard !files.isEmpty else { return false }
            Task { await library.importFiles(files) }
            return true
        }
    }

    /// The column after ARTIST: album names while searching, when it played in the history.
    private var extraColumn: String? {
        library.isSearching ? "ALBUM" : library.source == .history ? "PLAYED" : nil
    }

    /// The key of the deck that is playing (A first), to mark tracks that mix with it.
    private var mixKey: MusicalKey? {
        (deckA.isPlaying ? deckA : deckB.isPlaying ? deckB : deckA).track?.musicalKey
    }

    private var emptyText: String {
        if library.isSearching { return "No tracks match \"\(library.searchText.trimmed)\"." }
        if !library.filter.isEmpty { return "No tracks match the filter." }
        switch library.source {
        case .history: return "Nothing played yet."
        case .all: return "The library is empty. Add a playlist, or drop audio files here."
        case .smart: return "No tracks match this smart album."
        case .album: return "This album is empty. Drop audio files here to import them."
        }
    }

    private var tracksHeader: some View {
        HStack(spacing: 8) {
            if library.isSearching {
                Text("Search results").font(.system(size: 13, weight: .bold))
            } else if let album = library.selectedAlbum {
                Text(album.name)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Button { nameDraft = album.name; renaming = album } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.textDim)
                    .help("Rename album")
                Text("\(album.cachedCount) of \(album.trackCount) saved · \(formatTime(album.duration))")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textDim)
            } else if let smart = library.selectedSmartAlbum {
                Label(smart.name, systemImage: "gearshape").font(.system(size: 13, weight: .bold))
                Text(FilterBar.describe(smart.filter)).font(.system(size: 11)).foregroundColor(Theme.textDim)
            } else if library.source == .history {
                Text("History").font(.system(size: 13, weight: .bold))
                Button("Clear") { library.clearHistory() }
                    .controlSize(.small)
                    .disabled(library.tracks.isEmpty)
            } else {
                Text("All Tracks").font(.system(size: 13, weight: .bold))
            }
            Text("\(library.visibleTracks.count) shown").font(.system(size: 11)).foregroundColor(Theme.textDim)
            Spacer(minLength: 0)
            Button {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.allowedContentTypes = [.audio]
                if panel.runModal() == .OK { Task { await library.importFiles(panel.urls) } }
            } label: {
                Label("Import Files…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            .help("Copy audio files (mp3, m4a, wav, aiff, flac) into the library. You can also drop them on the list.")
        }
    }

    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        Button("Load on Deck A") { model.load(track, onto: .a) }
        Button("Load on Deck B") { model.load(track, onto: .b) }
        Divider()
        Button("Edit title and artist…") {
            titleDraft = track.title
            artistDraft = track.artist
            editing = track
        }
        Menu("Add to album") {
            ForEach(library.albums.filter { $0.id != library.selectedAlbumID || library.isSearching }) { album in
                Button(album.name) { library.add(track, to: album) }
            }
        }
        if !library.isSearching, let album = library.selectedAlbum {
            Button("Remove from \"\(album.name)\"") { library.remove(track, from: album) }
        }
        Divider()
        if track.isCached {
            if let name = track.fileName {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.audio.appendingPathComponent(name)])
                }
            }
            if !track.isLocal {
                Button("Delete download") { library.deleteDownload(track) }
            }
        } else {
            Button("Download") { Task { _ = try? await library.audioFile(for: track) } }
        }
    }
}

/// A binding that is true while the optional holds a value; setting false clears it.
private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
}

private struct InlineError: View {
    let message: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.system(size: 11)).lineLimit(3).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .padding(8)
        .foregroundColor(.white)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.65)))
    }
}

private struct AlbumRow: View {
    let album: Album
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: album.sourceURL == nil ? "square.stack" : "opticaldisc")
                .foregroundColor(Theme.textDim)
                .frame(width: 16)
            Text(album.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text("\(album.trackCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textDim)
        }
    }
}

// MARK: Track table

/// Column widths shared by the header and the rows.
private enum Col {
    static let status: CGFloat = 14
    static let number: CGFloat = 28
    static let bpm: CGFloat = 44
    static let time: CGFloat = 44
    static let decks: CGFloat = 74
    static let key: CGFloat = 32
}

private struct ColumnHeader: View {
    let extraColumn: String?
    @Binding var sort: TrackSort?

    var body: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: Col.status)
            label("#", nil).frame(width: Col.number, alignment: .trailing)
            label("TITLE", .title).frame(maxWidth: .infinity, alignment: .leading)
            label("ARTIST", .artist).frame(maxWidth: .infinity, alignment: .leading)
            if let extraColumn { label(extraColumn, nil).frame(maxWidth: .infinity, alignment: .leading) }
            label("KEY", .key).frame(width: Col.key, alignment: .trailing)
            label("BPM", .bpm).frame(width: Col.bpm, alignment: .trailing)
            label("TIME", .duration).frame(width: Col.time, alignment: .trailing)
            label("LOAD", nil).frame(width: Col.decks)
        }
        .padding(.vertical, 4)
    }

    /// Click a column to sort by it; again to reverse; a third time to go back to the album order.
    @ViewBuilder
    private func label(_ s: String, _ column: TrackSort.Column?) -> some View {
        let active = column != nil && sort?.column == column
        let text = HStack(spacing: 2) {
            Text(s)
            if active { Image(systemName: sort!.ascending ? "chevron.up" : "chevron.down") }
        }
        .font(.system(size: 9, weight: .heavy))
        .foregroundColor(active ? .white : Theme.textDim)
        if let column {
            Button {
                if sort?.column != column { sort = TrackSort(column: column) }
                else if sort!.ascending { sort!.ascending = false }
                else { sort = nil }
            } label: { text }
            .buttonStyle(.plain)
        } else {
            text
        }
    }
}

private struct TrackRow: View {
    let number: Int
    let track: Track
    let activity: String?
    /// Show `albumNames` (albums in search, deck and time in the history).
    let extraColumn: Bool
    /// Decks this track is loaded on now.
    let onDecks: [DeckID]
    /// The playing deck's key; a track that mixes with it shows its key in green.
    let mixesWith: MusicalKey?
    let load: (DeckID) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(track.isCached ? Theme.playGreen : Color.white.opacity(0.18))
                .frame(width: 6, height: 6)
                .frame(width: Col.status)
                .help(track.isLocal ? "Imported file" : track.isCached ? "Saved on this Mac" : "Not downloaded yet")
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .frame(width: Col.number, alignment: .trailing)
            HStack(spacing: 4) {
                ForEach(onDecks) { d in
                    Text(d.label)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(width: 12, height: 12)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Theme.deck(d)))
                }
                if track.isLocal {
                    Image(systemName: "doc").font(.system(size: 9)).foregroundColor(Theme.textDim)
                }
                Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.artist.isEmpty ? "—" : track.artist)
                .font(.system(size: 12)).foregroundColor(Theme.textDim).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if extraColumn {
                Text(track.albumNames.isEmpty ? "—" : track.albumNames)
                    .font(.system(size: 11)).foregroundColor(Theme.textDim).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let activity {
                Text(activity)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.amber)
                    .frame(width: Col.key + Col.bpm + Col.time + 16, alignment: .trailing)
            } else {
                Text(track.musicalKey?.camelot ?? "")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(keyColor)
                    .frame(width: Col.key, alignment: .trailing)
                    .help(track.musicalKey.map { "Key \($0.name)" + (keyColor == Theme.playGreen ? ", mixes with the playing deck" : "") } ?? "")
                Text(track.bpm.map { String(format: "%.1f", $0) } ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textDim)
                    .frame(width: Col.bpm, alignment: .trailing)
                Text(track.duration.map(formatTime) ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textDim)
                    .frame(width: Col.time, alignment: .trailing)
            }
            HStack(spacing: 4) {
                ForEach(DeckID.allCases) { deck in
                    Button { load(deck) } label: {
                        Text(deck.label)
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(Theme.deck(deck))
                            .frame(width: 30, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.deck(deck).opacity(0.6)))
                    }
                    .buttonStyle(PressableStyle())
                    .help("Load on deck \(deck.label)")
                }
            }
            .frame(width: Col.decks)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var keyColor: Color {
        guard let k = track.musicalKey, let m = mixesWith else { return Theme.textDim }
        return k.isCompatible(with: m) ? Theme.playGreen : Theme.textDim
    }
}

/// Quick filter over the list: saved only, a BPM range, and keys that mix with a deck.
private struct FilterBar: View {
    @ObservedObject var library: Library
    @ObservedObject var deckA: DeckState
    @ObservedObject var deckB: DeckState
    let saveAsSmartAlbum: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease").foregroundColor(Theme.textDim)
            Toggle("Saved only", isOn: $library.filter.downloadedOnly)
                .toggleStyle(.checkbox)
            PanelLabel("BPM")
            bpmField("min", $library.filter.minBPM)
            Text("–").foregroundColor(Theme.textDim)
            bpmField("max", $library.filter.maxBPM)
            Menu {
                Button("Any key") { library.filter.compatibleKey = nil }
                ForEach([deckA, deckB], id: \.deck) { d in
                    if let k = d.track?.musicalKey {
                        Button("Mixes with deck \(d.deck.label): \(k.name) (\(k.camelot))") { library.filter.compatibleKey = k.name }
                    }
                }
            } label: {
                Text(library.filter.compatibleKey.map { "Key mixes with \($0)" } ?? "Any key")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show only tracks whose key mixes with a deck (Camelot wheel neighbours)")
            Spacer(minLength: 0)
            if !library.filter.isEmpty {
                Button("Save as Smart Album…", action: saveAsSmartAlbum).controlSize(.small)
                Button("Clear") { library.filter = TrackFilter() }.controlSize(.small)
            }
        }
        .font(.system(size: 11))
    }

    private func bpmField(_ prompt: String, _ value: Binding<Double?>) -> some View {
        TextField(prompt, value: value, format: .number.precision(.fractionLength(0...1)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 52)
    }

    /// "120–128 BPM · mixes with Am · saved only".
    static func describe(_ f: TrackFilter) -> String {
        var parts: [String] = []
        switch (f.minBPM, f.maxBPM) {
        case let (lo?, hi?): parts.append(String(format: "%.0f–%.0f BPM", lo, hi))
        case let (lo?, nil): parts.append(String(format: "from %.0f BPM", lo))
        case let (nil, hi?): parts.append(String(format: "up to %.0f BPM", hi))
        default: break
        }
        if let k = f.compatibleKey { parts.append("mixes with \(k)") }
        if f.downloadedOnly { parts.append("saved only") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Auto DJ

private struct AutoDJBar: View {
    @ObservedObject var auto: AutoDJ
    let start: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { auto.isOn ? auto.stop() : start() } label: {
                Label(auto.isOn ? "Stop Auto DJ" : "Auto DJ", systemImage: auto.isOn ? "stop.fill" : "shuffle")
            }
            .controlSize(.small)
            .tint(auto.isOn ? Theme.amber : nil)
            .help("Play the tracks in the list on alternate decks, with crossfades")
            if auto.isOn {
                Button("Skip") { auto.skip() }.controlSize(.small)
            }
            Toggle("Beatmix", isOn: $auto.beatmix)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11))
                .help("Mix on phrase boundaries, match tempo and beats, and swap the basses")
            PanelLabel("FADE")
            Slider(value: $auto.fadeSeconds, in: 1...30, step: 1).frame(width: 80).controlSize(.small)
            Text("\(Int(auto.fadeSeconds))s")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(.white)
                .frame(width: 24, alignment: .leading)
            if auto.phase != .idle {
                HStack(spacing: 4) {
                    Circle().fill(phaseColor).frame(width: 7, height: 7)
                    Text(phaseText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(phaseColor)
                }
            }
        }
    }

    private var phaseText: String {
        switch auto.phase {
        case .idle: return ""
        case .playing: return "PLAYING"
        case .crossfading: return "CROSSFADING"
        case .waitingForBuffer: return "LOADING NEXT…"
        case .finished: return "FINISHED"
        }
    }

    private var phaseColor: Color {
        switch auto.phase {
        case .idle: return Theme.textDim
        case .playing: return .white
        case .crossfading: return Theme.amber
        case .waitingForBuffer: return .yellow
        case .finished: return Theme.playGreen
        }
    }
}

/// The live Auto DJ queue: every track, the deck it played on, and its state.
struct QueuePanel: View {
    @ObservedObject var auto: AutoDJ

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                PanelLabel("AUTO DJ QUEUE", color: Theme.amber)
                Spacer()
                Text("\(auto.currentIndex + 1)/\(auto.queue.count)")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.textDim)
            }
            if !auto.status.isEmpty {
                Text(auto.status).font(.system(size: 10)).foregroundColor(Theme.textDim).lineLimit(2)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(auto.queue) { item in
                            QueueRow(item: item, isCurrent: item.id == auto.currentIndex).id(item.id)
                        }
                    }
                }
                .onChange(of: auto.currentIndex) { _, i in
                    withAnimation { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
        .padding(10)
    }
}

struct QueueRow: View {
    let item: QueueItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("\(item.id + 1)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .frame(width: 20, alignment: .trailing)
            Text(item.deck?.label ?? "·")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundColor(.black)
                .frame(width: 14, height: 14)
                .background(Circle().fill(item.deck.map(Theme.deck) ?? Color.white.opacity(0.15)))
            Text(item.track.title)
                .font(.system(size: 11, weight: isCurrent ? .bold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(color)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(isCurrent ? Theme.amber.opacity(0.15) : .clear))
        .opacity(item.state == .done ? 0.5 : 1)
    }

    private var label: String {
        switch item.state {
        case .waiting: return ""
        case .downloading: return "LOAD"
        case .ready: return "NEXT"
        case .playing: return "ON \(item.deck?.label ?? "")"
        case .done: return "✓"
        case .failed: return "FAILED"
        }
    }

    private var color: Color {
        switch item.state {
        case .waiting, .done: return Theme.textDim
        case .downloading: return .yellow
        case .ready: return .cyan
        case .playing: return Theme.amber
        case .failed: return .red
        }
    }
}
