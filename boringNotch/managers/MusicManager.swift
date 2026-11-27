//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import AppKit
import Combine
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "heart.fill",
    accessibilityDescription: "Album Art"
)!

class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()

    // Active controller
    private var activeController: (any MediaControllerProtocol)?

    // Published properties for UI
    @Published var songTitle: String = "I'm Handsome"
    @Published var artistName: String = "Me"
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = "Self Love"
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    // Generation guard: responses from a previous track are dropped instead of overwriting the new track's lyrics
    private var lyricsFetchGeneration = 0
    // In-memory cache of resolved lyrics, keyed by track identity (title + artist + album + duration)
    private var lyricsCache: [String: (plain: String, synced: [(time: Double, text: String)])] = [:]
    @Published var canFavoriteTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false

    private var artworkData: Data? = nil

    // Store last values at the time artwork was changed
    private var lastArtworkTitle: String = "I'm Handsome"
    private var lastArtworkArtist: String = "Me"
    private var lastArtworkAlbum: String = "Self Love"
    private var lastArtworkBundleIdentifier: String? = nil

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                self?.setActiveControllerBasedOnPreference()
            }
            .store(in: &cancellables)

        // Initialize deprecation check asynchronously
        Task { @MainActor in
            do {
                self.isNowPlayingDeprecated = try await self.mediaChecker.checkDeprecationStatus()
                print("Deprecation check completed: \(self.isNowPlayingDeprecated)")
            } catch {
                print("Failed to check deprecation status: \(error). Defaulting to false.")
                self.isNowPlayingDeprecated = false
            }
            
            // Initialize the active controller after deprecation check
            self.setActiveControllerBasedOnPreference()
        }
    }

    deinit {
        destroy()
    }
    
    public func destroy() {
        debounceIdleTask?.cancel()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Release active controller
        activeController = nil
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func setActiveControllerBasedOnPreference() {
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = (self.isNowPlayingDeprecated && preferredType == .nowPlaying)
            ? .appleMusic
            : preferredType

        if let controller = createController(for: controllerType) {
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller
        
        self.canFavoriteTrack = controller.supportsFavorite

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Check for playback state changes (playing/paused)
        if state.isPlaying != self.isPlaying {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

            if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty {
                self.updateSneakPeek()
            }
        }

        // Check for changes in track metadata using last artwork change values
        let titleChanged = state.title != self.lastArtworkTitle
        let artistChanged = state.artist != self.lastArtworkArtist
        let albumChanged = state.album != self.lastArtworkAlbum
        let bundleChanged = state.bundleIdentifier != self.lastArtworkBundleIdentifier

        // Check for artwork changes
        let artworkChanged = state.artwork != nil && state.artwork != self.artworkData
        let hasContentChange = titleChanged || artistChanged || albumChanged || artworkChanged || bundleChanged

        // Handle artwork and visual transitions for changed content
        if hasContentChange {
            self.triggerFlipAnimation()

            if artworkChanged, let artwork = state.artwork {
                self.updateArtwork(artwork)
            } else if state.artwork == nil {
                // Try to use app icon if no artwork but track changed
                if let appIconImage = AppIconAsNSImage(for: state.bundleIdentifier) {
                    self.usingAppIconForArtwork = true
                    self.updateAlbumArt(newAlbumArt: appIconImage)
                }
            }
            self.artworkData = state.artwork

            if artworkChanged || state.artwork == nil {
                // Update last artwork change values
                self.lastArtworkTitle = state.title
                self.lastArtworkArtist = state.artist
                self.lastArtworkAlbum = state.album
                self.lastArtworkBundleIdentifier = state.bundleIdentifier
            }

            // Only update sneak peek if there's actual content and something changed
            if !state.title.isEmpty && !state.artist.isEmpty && state.isPlaying {
                self.updateSneakPeek()
            }

            // Fetch lyrics on content change
            self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist, album: state.album, duration: state.duration)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume
        
        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }
        
        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        if state.isFavorite != self.isFavoriteTrack {
            self.isFavoriteTrack = state.isFavorite
        }
        
        if volumeChanged {
            self.volume = state.volume
        }
        
        self.timestampDate = state.lastUpdated
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        // Toggle based on current state
        setFavorite(!isFavoriteTrack)
    }

    @MainActor
    private func toggleAppleMusicFavorite() async {
        let script = """
        tell application \"Music\"
            if it is running then
                try
                    set loved of current track to (not loved of current track)
                    return loved of current track
                on error
                    return false
                end try
            else
                return false
            end if
        end tell
        """

        if let result = try? await AppleScriptHelper.execute(script) {
            let loved = result.booleanValue
            self.isFavoriteTrack = loved
            self.forceUpdate()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        guard let controller = activeController else { return }

        Task { @MainActor in
            await controller.setFavorite(favorite)
            try? await Task.sleep(for: .milliseconds(150))
            await controller.updatePlaybackInfo()
        }
    }

    /// Placeholder dislike function
    func dislikeCurrentTrack() {
        setFavorite(false)
    }

    // MARK: - Lyrics
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String, album: String = "", duration: TimeInterval = 0) {
        // Every track change bumps the generation so stale in-flight fetches are ignored
        lyricsFetchGeneration += 1
        let generation = lyricsFetchGeneration
        let cacheKey = lyricsCacheKey(title: title, artist: artist, album: album, duration: duration)

        guard Defaults[.enableLyrics], !title.isEmpty else {
            DispatchQueue.main.async {
                self.isFetchingLyrics = false
                self.currentLyrics = ""
            }
            return
        }

        // Serve from the in-memory cache when this track was already resolved
        if let cached = lyricsCache[cacheKey] {
            DispatchQueue.main.async {
                guard generation == self.lyricsFetchGeneration else { return }
                self.currentLyrics = cached.plain
                self.syncedLyrics = cached.synced
                self.isFetchingLyrics = false
            }
            return
        }

        // Prefer native Apple Music lyrics when available
        if let bundleIdentifier = bundleIdentifier, bundleIdentifier.contains("com.apple.Music") {
            Task { @MainActor in
                self.isFetchingLyrics = true
                self.currentLyrics = ""
                self.syncedLyrics = []
                do {
                    let script = """
                    tell application \"Music\"
                        if it is running then
                            if player state is playing or player state is paused then
                                try
                                    set l to lyrics of current track
                                    if l is missing value then
                                        return \"\"
                                    else
                                        return l
                                    end if
                                on error
                                    return \"\"
                                end try
                            else
                                return \"\"
                            end if
                        else
                            return \"\"
                        end if
                    end tell
                    """
                    if let result = try await AppleScriptHelper.execute(script), let lyricsString = result.stringValue, !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        guard generation == self.lyricsFetchGeneration else { return }
                        let resolved = lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.lyricsCache[cacheKey] = (plain: resolved, synced: [])
                        self.currentLyrics = resolved
                        self.isFetchingLyrics = false
                        self.syncedLyrics = []
                        return
                    }
                } catch {
                    // fall through to web lookup
                }
                await self.fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration, generation: generation)
            }
        } else {
            Task { @MainActor in
                self.isFetchingLyrics = true
                self.currentLyrics = ""
                self.syncedLyrics = []
                await self.fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration, generation: generation)
            }
        }
    }

    /// Cache key for a track: normalized title/artist/album plus whole-second duration
    private func lyricsCacheKey(title: String, artist: String, album: String, duration: TimeInterval) -> String {
        let parts = [title, artist, album].map { normalizedQuery($0).lowercased().trimmingCharacters(in: .whitespaces) }
        return parts.joined(separator: "|") + "|\(Int(duration.rounded()))"
    }

    private func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    @MainActor
    private func fetchLyricsFromWeb(title: String, artist: String, album: String = "", duration: TimeInterval = 0, generation: Int = 0, isRetry: Bool = false) async {
        guard generation == lyricsFetchGeneration else { return }
        let cleanTitle = normalizedQuery(title)
        let cleanArtist = normalizedQuery(artist)
        let cleanAlbum = normalizedQuery(album)
        let cacheKey = lyricsCacheKey(title: title, artist: artist, album: album, duration: duration)
        guard let encodedTitle = cleanTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = cleanArtist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            applyLyricsResult(plain: "", synced: [], generation: generation)
            return
        }

        // Step 1: exact match via LRCLIB /api/get (album + duration pin the right version)
        var getURLString = "https://lrclib.net/api/get?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        if !cleanAlbum.isEmpty, let encodedAlbum = cleanAlbum.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            getURLString += "&album_name=\(encodedAlbum)"
        }
        let durationSeconds = Int(duration.rounded())
        if durationSeconds > 0 {
            getURLString += "&duration=\(durationSeconds)"
        }
        if let exact = await fetchLyricsResult(from: getURLString), !exact.plain.isEmpty || !exact.synced.isEmpty {
            guard generation == lyricsFetchGeneration else { return }
            applyLyricsResult(plain: exact.plain, synced: exact.synced, generation: generation, cacheKey: cacheKey)
            return
        }

        // Step 2: fall back to /api/search and pick the best candidate instead of the first hit
        let searchURLString = "https://lrclib.net/api/search?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        do {
            guard let searchURL = URL(string: searchURLString) else {
                applyLyricsResult(plain: "", synced: [], generation: generation)
                return
            }
            let (data, response) = try await URLSession.shared.data(from: searchURL)
            guard generation == lyricsFetchGeneration else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let best = pickBestLyricsCandidate(jsonArray, duration: duration, artist: artist) else {
                applyLyricsResult(plain: "", synced: [], generation: generation)
                return
            }
            // Prefer plain lyrics (syncedLyrics may also be present)
            let plain = (best["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let synced = (best["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolved = plain.isEmpty ? synced : plain
            applyLyricsResult(plain: resolved, synced: parseLRC(synced), generation: generation, cacheKey: cacheKey)
        } catch {
            // One retry after a short delay, only while this is still the current track
            guard !isRetry else {
                applyLyricsResult(plain: "", synced: [], generation: generation)
                return
            }
            try? await Task.sleep(for: .milliseconds(1500))
            guard generation == lyricsFetchGeneration else { return }
            await fetchLyricsFromWeb(title: title, artist: artist, album: album, duration: duration, generation: generation, isRetry: true)
        }
    }

    /// Fetches lyrics from an LRCLIB endpoint returning a single JSON object (e.g. /api/get).
    /// Returns nil on 404, non-200, network error, or when the track has no lyrics here.
    private func fetchLyricsResult(from urlString: String) async -> (plain: String, synced: [(time: Double, text: String)])? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let plain = (json["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let synced = (json["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !plain.isEmpty || !synced.isEmpty else { return nil }
            // Prefer plain lyrics (syncedLyrics may also be present)
            return (plain.isEmpty ? synced : plain, parseLRC(synced))
        } catch {
            return nil
        }
    }

    /// Picks the best LRCLIB search result: synced lyrics first, then closest duration, then artist match.
    private func pickBestLyricsCandidate(_ candidates: [[String: Any]], duration: TimeInterval, artist: String) -> [String: Any]? {
        let usable = candidates.filter { candidate in
            let plain = (candidate["plainLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let synced = (candidate["syncedLyrics"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !plain.isEmpty || !synced.isEmpty
        }
        guard !usable.isEmpty else { return nil }
        let artistLower = artist.lowercased()
        return usable.sorted { lhs, rhs in
            let lhsSynced = !((lhs["syncedLyrics"] as? String) ?? "").isEmpty
            let rhsSynced = !((rhs["syncedLyrics"] as? String) ?? "").isEmpty
            if lhsSynced != rhsSynced { return lhsSynced }
            if duration > 0 {
                let lhsDiff = abs((lhs["duration"] as? Double ?? 0) - duration)
                let rhsDiff = abs((rhs["duration"] as? Double ?? 0) - duration)
                if lhsDiff != rhsDiff { return lhsDiff < rhsDiff }
            }
            let lhsArtist = ((lhs["artistName"] as? String) ?? "").lowercased()
            let rhsArtist = ((rhs["artistName"] as? String) ?? "").lowercased()
            let lhsMatch = !artistLower.isEmpty && (lhsArtist.contains(artistLower) || artistLower.contains(lhsArtist))
            let rhsMatch = !artistLower.isEmpty && (rhsArtist.contains(artistLower) || artistLower.contains(rhsArtist))
            if lhsMatch != rhsMatch { return lhsMatch }
            return false
        }.first
    }

    /// Writes a fetched lyrics result, dropping it when a newer track has started meanwhile.
    @MainActor
    private func applyLyricsResult(plain: String, synced: [(time: Double, text: String)], generation: Int, cacheKey: String? = nil) {
        guard generation == lyricsFetchGeneration else { return }
        if let cacheKey = cacheKey {
            lyricsCache[cacheKey] = (plain: plain, synced: synced)
        }
        self.currentLyrics = plain
        self.syncedLyrics = synced
        self.isFetchingLyrics = false
    }

    // MARK: - Synced lyrics helpers
    private func parseLRC(_ lrc: String) -> [(time: Double, text: String)] {
        var result: [(time: Double, text: String)] = []
        // \r\n safe: split on any newline sequence
        let lines = lrc.components(separatedBy: CharacterSet.newlines)

        // First pass: [offset:+/-ms] shifts every timestamp in the file
        var offsetSeconds = 0.0
        if let offsetRegex = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#) {
            for rawLine in lines {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let nsLine = line as NSString
                if let match = offsetRegex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                   let ms = Double(nsLine.substring(with: match.range(at: 1))) {
                    offsetSeconds = ms / 1000.0
                    break
                }
            }
        }

        // One line may carry several timestamps: [00:12.00][00:15.50]text
        // Fraction is 1-3 digits: .5 = 500ms, .05 = 50ms, .005 = 5ms
        let timestampPattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        let metadataPattern = #"^\[(ti|ar|al|au|by|length|offset|re|ve):"#
        guard let timestampRegex = try? NSRegularExpression(pattern: timestampPattern),
              let metadataRegex = try? NSRegularExpression(pattern: metadataPattern, options: .caseInsensitive) else { return [] }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            // Skip metadata lines such as [ti:...], [ar:...], [al:...], [length:...]
            if metadataRegex.firstMatch(in: line, range: fullRange) != nil { continue }
            let matches = timestampRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }
            // Lyric text follows the last timestamp on the line
            let lastMatch = matches[matches.count - 1]
            let textStart = lastMatch.range.location + lastMatch.range.length
            let text = nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fracRange = match.range(at: 3)
                let fraction = fracRange.location != NSNotFound ? nsLine.substring(with: fracRange) : "0"
                let fractionValue = Double(fraction) ?? 0
                let divisor = pow(10.0, Double(fraction.count))
                let time = max(0, minutes * 60 + seconds + fractionValue / divisor + offsetSeconds)
                result.append((time, text))
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }

    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return syncedLyrics[idx].text
    }

    /// The first synced line after the one playing at `elapsed` ("" when there is none)
    func nextLyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return "" }
        // Same binary search as lyricLine(at:): idx is the current line
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        let nextIndex = idx + 1
        return nextIndex < syncedLyrics.count ? syncedLyrics[nextIndex].text : ""
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func updateArtwork(_ artworkData: Data) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            if let artworkImage = NSImage(data: artworkData) {
                DispatchQueue.main.async { [weak self] in
                    self?.usingAppIconForArtwork = false
                    self?.updateAlbumArt(newAlbumArt: artworkImage)
                }
            }
        }
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                try? await Task.sleep(for: .seconds(Defaults[.waitInterval]))
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    private var workItem: DispatchWorkItem?

    func updateAlbumArt(newAlbumArt: NSImage) {
        workItem?.cancel()
        withAnimation(.smooth) {
            self.albumArt = newAlbumArt
            if Defaults[.coloredSpectrogram] {
                self.calculateAverageColor()
            }
        }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        guard isPlaying else { return min(elapsedTime, songDuration) }

        let timeDifference = date.timeIntervalSince(timestampDate)
        let estimated = elapsedTime + (timeDifference * playbackRate)
        return min(max(0, estimated), songDuration)
    }

    func calculateAverageColor() {
        albumArt.averageColor { [weak self] color in
            DispatchQueue.main.async {
                withAnimation(.smooth) {
                    self?.avgColor = color ?? .white
                }
            }
        }
    }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Public Methods for controlling playback
    func playPause() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func play() {
        Task {
            await activeController?.play()
        }
    }

    func pause() {
        Task {
            await activeController?.pause()
        }
    }

    func toggleShuffle() {
        Task {
            await activeController?.toggleShuffle()
        }
    }

    func toggleRepeat() {
        Task {
            await activeController?.toggleRepeat()
        }
    }
    
    func togglePlay() {
        Task {
            await activeController?.togglePlay()
        }
    }

    func nextTrack() {
        Task {
            await activeController?.nextTrack()
        }
    }

    func previousTrack() {
        Task {
            await activeController?.previousTrack()
        }
    }

    func seek(to position: TimeInterval) {
        Task {
            await activeController?.seek(to: position)
        }
    }
    func skip(seconds: TimeInterval) {
        let newPos = min(max(0, elapsedTime + seconds), songDuration)
        seek(to: newPos)
    }
    
    func setVolume(to level: Double) {
        if let controller = activeController {
            Task {
                await controller.setVolume(level)
            }
        }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        // Request immediate update from the active controller
        Task { [weak self] in
            if self?.activeController?.isActive() == true {
                if let youtubeController = self?.activeController as? YouTubeMusicController {
                    await youtubeController.pollPlaybackState()
                } else {
                    await self?.activeController?.updatePlaybackInfo()
                }
                // Sync volume after update
                await self?.syncVolumeFromActiveApp()
            }
        }
    }
    
    
    func syncVolumeFromActiveApp() async {
        guard let bundleID = bundleIdentifier, !bundleID.isEmpty else { return }
        
        var script: String?
        if bundleID == "com.apple.Music" {
            script = "tell application \"Music\" to get sound volume"
        } else if bundleID == "com.spotify.client" {
            script = "tell application \"Spotify\" to get sound volume"
        } else {
            // For unsupported apps, don't sync volume
            return
        }
        
        if let volumeScript = script,
           let result = try? await AppleScriptHelper.execute(volumeScript) {
            let volumeValue = result.int32Value
            let currentVolume = Double(volumeValue) / 100.0
            
            await MainActor.run {
                if abs(currentVolume - self.volume) > 0.01 {
                    self.volume = currentVolume
                }
            }
        }
    }
}
