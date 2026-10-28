import AVFoundation
import SwiftUI
import UIKit

// MARK: - Playing from memory

/// Serves a decrypted clip to AVPlayer straight from memory. AVFoundation
/// asks for byte ranges of a custom URL and gets them sliced from `data`, so
/// a video's plaintext is never written to disk to be played: the cache and
/// Storage only ever hold its ciphertext.
final class InMemoryClipLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "huddlepal-clip"
    private static let queue = DispatchQueue(label: "com.huddlepals.clip-loader")
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    /// An asset that reads from this loader. AVFoundation holds its delegate
    /// weakly: keep this loader alive as long as the asset plays.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://clip/\(UUID().uuidString).mp4")!)
        asset.resourceLoader.setDelegate(self, queue: Self.queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = AVFileType.mp4.rawValue
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        if let request = loadingRequest.dataRequest {
            guard let range = Self.byteRange(
                currentOffset: request.currentOffset, requestedOffset: request.requestedOffset,
                requestedLength: request.requestedLength, toEnd: request.requestsAllDataToEndOfResource,
                clipLength: data.count
            ) else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            request.respond(with: data.subdata(in: range))
        }
        loadingRequest.finishLoading()
        return true
    }

    /// The bytes a data request still wants, from where it has got to, cut
    /// off at the clip's end; nil when that's outside the clip.
    static func byteRange(
        currentOffset: Int64, requestedOffset: Int64, requestedLength: Int, toEnd: Bool, clipLength: Int
    ) -> Range<Int>? {
        let start = Int(currentOffset)
        guard start >= 0, start <= clipLength else { return nil }
        let wanted = toEnd
            ? clipLength - start
            : min(requestedLength - Int(currentOffset - requestedOffset), clipLength - start)
        return start..<(start + max(wanted, 0))
    }
}

/// Decrypted clips, in memory only, so scrolling back to a video doesn't
/// decrypt it again. NSCache drops them under memory pressure; sign-out
/// empties it.
final class DecryptedClipCache: @unchecked Sendable {
    static let shared = DecryptedClipCache()
    private let cache = NSCache<NSString, NSData>()

    init() {
        // A few clips (4 MB at most each).
        cache.totalCostLimit = 16_000_000
    }

    func clip(for key: String) -> Data? {
        cache.object(forKey: key as NSString) as Data?
    }

    func store(_ clip: Data, for key: String) {
        cache.setObject(clip as NSData, forKey: key as NSString, cost: clip.count)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

/// One clip, looping, from memory. It keeps playing until it's paused here:
/// AVPlayer also stops on its own when something else takes the audio
/// session (the camera shutting down after a recording, a call) or the app
/// goes to the background, and it then starts again by itself.
@MainActor
final class LoopingClipPlayer {
    let player = AVQueuePlayer()
    private let loader: InMemoryClipLoader
    private let looper: AVPlayerLooper
    private var wantsToPlay = false
    private var statusObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []

    /// `range` (seconds) loops just that part: a clip being trimmed.
    init(clip: Data, range: ClosedRange<Double>? = nil) {
        loader = InMemoryClipLoader(data: clip)
        let item = AVPlayerItem(asset: loader.makeAsset())
        if let range {
            looper = AVPlayerLooper(player: player, templateItem: item, timeRange: CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 600)
            ))
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
        statusObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .paused else { return }
            Task { @MainActor in self?.resumeSoon() }
        }
        for name in [AVAudioSession.interruptionNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeSoon() }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func play() {
        wantsToPlay = true
        player.play()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
    }

    /// Times the clip has started over.
    var loopCount: Int { looper.loopCount }

    /// A moment later, so whatever stopped it (the camera's audio session,
    /// a notification sound) has finished; then only if it's still meant
    /// to play and can.
    private func resumeSoon() {
        guard wantsToPlay else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.wantsToPlay, self.player.timeControlStatus == .paused,
                  self.looper.status != .failed, UIApplication.shared.applicationState != .background
            else { return }
            self.player.play()
        }
    }
}

/// Who gets the sound. Muted clips play alongside whatever else is playing
/// (ambient: the music keeps going); a clip someone unmutes takes the sound,
/// silent switch or not, like any video app, and gives it back when it stops.
enum PlaybackAudio {
    static func muted() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    }

    static func soundOn() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    static func release() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        muted()
    }
}

/// AVPlayerLayer, filling its frame.
struct ClipPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - A video drop

/// A video deposit: its poster (as any photo shows, locked while its key
/// isn't here) and, over it, the clip looping from memory, with play/pause
/// and sound buttons on its bottom corners. The feed starts muted (a tap on
/// the video unmutes), the detail screen with sound (a tap there plays or
/// pauses). Pauses off screen and in the background; one paused by hand
/// stays paused until it's played again.
struct DepositVideoPlayer: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.scenePhase) private var scenePhase
    let deposit: Deposit
    var startsMuted = true
    /// A tap on the video plays or pauses it (the detail screen), instead
    /// of turning the sound on or off (the feed).
    var tapPlaysAndPauses = false

    @State private var clipPlayer: LoopingClipPlayer?
    @State private var isMuted = true
    @State private var isPaused = false
    @State private var isOnScreen = false

    var body: some View {
        ZStack {
            LocalDepositImage(deposit: deposit)
            if let clipPlayer {
                ClipPlayerView(player: clipPlayer.player)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            VideoBadge(durationMs: deposit.durationMs)
                .padding(10)
        }
        .overlay {
            if clipPlayer != nil, isPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.black.opacity(0.45), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { togglePlayback() }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if clipPlayer != nil {
                HStack {
                    control(isPaused ? "play.fill" : "pause.fill") { togglePlayback() }
                    Spacer()
                    control(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { toggleSound() }
                }
                .padding(4)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPaused)
        .contentShape(Rectangle())
        .onTapGesture {
            if tapPlaysAndPauses { togglePlayback() } else { toggleSound() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video by \(deposit.author?.displayName ?? "Former member")\(deposit.durationMs.map { ", \(Self.seconds($0)) seconds" } ?? "")")
        .accessibilityValue(isPaused ? "Paused" : "")
        .accessibilityAddTraits(.startsMediaSession)
        .accessibilityAction(named: isPaused ? "Play" : "Pause") { togglePlayback() }
        .accessibilityAction(named: isMuted ? "Unmute" : "Mute") { toggleSound() }
        .task(id: "\(deposit.id)#\(deps.session.photoKeysVersion)") { await load() }
        .onAppear {
            isOnScreen = true
            if !isPaused { clipPlayer?.play() }
        }
        .onDisappear {
            isOnScreen = false
            clipPlayer?.pause()
            if !isMuted { PlaybackAudio.release() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isOnScreen, !isPaused { clipPlayer?.play() } else { clipPlayer?.pause() }
        }
    }

    /// A round button on the video's corner, its tap area 44 pt.
    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.5), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .contentTransition(.symbolEffect(.replace))
    }

    private func togglePlayback() {
        guard let clipPlayer else { return }
        isPaused.toggle()
        if isPaused {
            clipPlayer.pause()
            // Paused with sound on: give the sound back meanwhile.
            if !isMuted { PlaybackAudio.release() }
        } else {
            if !isMuted { PlaybackAudio.soundOn() }
            clipPlayer.play()
        }
        Haptics.light()
    }

    private func load() async {
        guard clipPlayer == nil, let path = deposit.localVideoPath, let huddleID = deposit.huddle?.id else { return }
        let key = "\(deposit.id.uuidString)#\(path)"
        var clip = DecryptedClipCache.shared.clip(for: key)
        if clip == nil {
            clip = await deps.mediaService.loadDepositPhoto(at: path, huddleID: huddleID, wrappedPhotoKey: deposit.wrappedPhotoKey)
            if let clip { DecryptedClipCache.shared.store(clip, for: key) }
        }
        // No key on this device yet: the poster shows its lock, and this
        // runs again when a key arrives.
        guard let clip else { return }
        let player = LoopingClipPlayer(clip: clip)
        isMuted = startsMuted
        player.isMuted = startsMuted
        if startsMuted { PlaybackAudio.muted() } else { PlaybackAudio.soundOn() }
        clipPlayer = player
        if isOnScreen, !isPaused { player.play() }
    }

    private func toggleSound() {
        guard let clipPlayer else { return }
        isMuted.toggle()
        clipPlayer.isMuted = isMuted
        if isMuted { PlaybackAudio.release() } else { PlaybackAudio.soundOn() }
        Haptics.light()
    }

    static func seconds(_ durationMs: Int) -> Int {
        max(1, Int((Double(durationMs) / 1000).rounded()))
    }
}

/// "▶︎ 0:06" on a video's corner: in the feed, the archive and detail.
struct VideoBadge: View {
    let durationMs: Int?

    var body: some View {
        Label {
            if let durationMs {
                Text(String(format: "0:%02d", DepositVideoPlayer.seconds(durationMs)))
            }
        } icon: {
            Image(systemName: "video.fill")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5), in: Capsule())
        .accessibilityLabel("Video")
    }
}

/// A just-recorded clip in Compose, looping from memory over its poster,
/// with its sound on (it's yours) and play/pause and sound buttons, a tap on
/// the video pausing it, as on the detail screen. Given `range`, it plays
/// just that part, with the trim bar between the buttons to change it.
struct ClipPreview: View {
    let clip: PreparedClip
    var range: Binding<ClosedRange<Double>>?

    @Environment(\.scenePhase) private var scenePhase
    @State private var clipPlayer: LoopingClipPlayer?
    @State private var frames: ClipFrames?
    @State private var isMuted = false
    @State private var isPaused = false
    /// The frame under a trim handle while it's dragged.
    @State private var scrubFrame: UIImage?
    @State private var scrubTask: Task<Void, Never>?

    private var playing: ClosedRange<Double> { range?.wrappedValue ?? 0...clip.seconds }

    var body: some View {
        video
            .overlay(alignment: .topLeading) {
                VideoBadge(durationMs: Int(((playing.upperBound - playing.lowerBound) * 1000).rounded()))
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { controls }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isPaused)
            .task(id: "\(clip.id)#\(playing.lowerBound)#\(playing.upperBound)") { play(playing) }
            .task(id: clip.id) {
                if range != nil { frames = ClipFrames(clip: clip.clip) }
            }
            .onDisappear {
                clipPlayer?.pause()
                if !isMuted { PlaybackAudio.release() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !isPaused, scrubFrame == nil { clipPlayer?.play() } else { clipPlayer?.pause() }
            }
    }

    /// Exactly the frame it's given: a video is taller (9:16) than the
    /// frames it's shown in, and the poster filling one must not stretch it
    /// and push what's below off the screen.
    private var video: some View {
        Color.clear
            .overlay {
                Image(uiImage: clip.posterImage)
                    .resizable()
                    .scaledToFill()
            }
            .overlay {
                if let clipPlayer {
                    ClipPlayerView(player: clipPlayer.player)
                }
            }
            .overlay {
                if let scrubFrame {
                    Image(uiImage: scrubFrame)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay { pausedMark }
            .contentShape(Rectangle())
            .onTapGesture { togglePlayback() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityTitle)
            .accessibilityValue(isPaused ? "Paused" : "")
            .accessibilityAddTraits(.startsMediaSession)
            .accessibilityAction(named: isPaused ? "Play" : "Pause") { togglePlayback() }
    }

    private var accessibilityTitle: String {
        let seconds = DepositVideoPlayer.seconds(Int((playing.upperBound - playing.lowerBound) * 1000))
        return "Your video, \(seconds) seconds"
    }

    @ViewBuilder
    private var pausedMark: some View {
        if isPaused, scrubFrame == nil {
            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(.black.opacity(0.45), in: Circle())
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    /// Play/pause, the trim bar (when trimming), and sound, over a shade.
    private var controls: some View {
        HStack(spacing: 4) {
            control(isPaused ? "play.fill" : "pause.fill", label: isPaused ? "Play" : "Pause") { togglePlayback() }
            if let range, let frames {
                ClipTrimBar(duration: clip.seconds, frames: frames, range: range) { scrub(to: $0) }
                    .padding(.horizontal, 4)
            } else {
                Spacer()
            }
            control(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: isMuted ? "Unmute" : "Mute") { toggleSound() }
        }
        .padding(4)
        .padding(.top, 28)
        .background(
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    /// A round button on the video, its tap area 44 pt.
    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.5), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A player for `part` of the clip, playing from its start.
    private func play(_ part: ClosedRange<Double>) {
        let player = LoopingClipPlayer(clip: clip.clip, range: range == nil ? nil : part)
        player.isMuted = isMuted
        if isMuted { PlaybackAudio.muted() } else { PlaybackAudio.soundOn() }
        clipPlayer?.pause()
        clipPlayer = player
        isPaused = false
        player.play()
    }

    private func togglePlayback() {
        guard let clipPlayer, scrubFrame == nil else { return }
        isPaused.toggle()
        if isPaused {
            clipPlayer.pause()
            if !isMuted { PlaybackAudio.release() }
        } else {
            if !isMuted { PlaybackAudio.soundOn() }
            clipPlayer.play()
        }
        Haptics.light()
    }

    private func toggleSound() {
        guard let clipPlayer else { return }
        isMuted.toggle()
        clipPlayer.isMuted = isMuted
        if isMuted { PlaybackAudio.release() } else { PlaybackAudio.soundOn() }
        Haptics.light()
    }

    /// While a handle is dragged: still, showing the frame under it. Let
    /// go (nil), the new part plays from its start.
    private func scrub(to time: Double?) {
        scrubTask?.cancel()
        guard let time else {
            scrubFrame = nil
            // Let go where it was: carry on (a new part gets a new player).
            if !isPaused { clipPlayer?.play() }
            return
        }
        clipPlayer?.pause()
        scrubTask = Task {
            let frame = await frames?.frame(at: time)
            if !Task.isCancelled, let frame { scrubFrame = frame }
        }
    }
}
