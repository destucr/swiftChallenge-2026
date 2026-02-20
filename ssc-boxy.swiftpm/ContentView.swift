import SwiftUI
import Foundation
import AVFoundation

public struct AudioTrack: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let filename: String
    public let artist: String?
}

public enum RadioFilter: String, CaseIterable {
    case amRadio = "AM Radio"
    case fmVintage = "FM Vintage"
    case hamRadio = "Ham Radio"
}

@MainActor
public class RadioAudioManager: NSObject, ObservableObject {
    public static let shared = RadioAudioManager()

    // Serial queue to ensure audio operations never overlap
    private let audioQueue = DispatchQueue(label: "com.destucr.boxy.audio")

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixerNode = AVAudioMixerNode()

    // Effects
    private let eqNode = AVAudioUnitEQ(numberOfBands: 3)
    private let distortionNode = AVAudioUnitDistortion()
    private let delayNode = AVAudioUnitDelay()

    // Noise and Beeps
    private let noisePlayerNode = AVAudioPlayerNode()
    private var noiseBuffer: AVAudioPCMBuffer?
    private let beepPlayerNode = AVAudioPlayerNode()
    private var beepBuffer: AVAudioPCMBuffer?
    private let heterodynePlayerNode = AVAudioPlayerNode()
    private var heterodyneBuffer: AVAudioPCMBuffer?

    private var uiSoundPlayer: AVAudioPlayer?
    private var activeTickPlayers: [AVAudioPlayer] = []
    private let maxTickPlayers = 8 // Limit concurrent tick sounds
    private let tickLock = NSLock()

    // Cached resources
    private var cachedSoundData: [String: Data] = [:]
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)

    // Simple debounce for track changes
    private var lastTrackChangeTime = Date.distantPast
    private let minTrackChangeInterval: TimeInterval = 0.15

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var isMonitoring = false
    @Published var isAutoEchoEnabled = false
    @Published var currentFilter: RadioFilter = .hamRadio
    @Published var volume: Double = 0.5 {
        didSet {
            mixerNode.outputVolume = Float(volume)
        }
    }

    @Published var availableTracks: [AudioTrack] = [
        AudioTrack(title: "Beethoven - Coriolan Overture", filename: "Classicals.de - Beethoven - Coriolan Overture - Op.62", artist: "Beethoven"),
        AudioTrack(title: "Brahms - Fantasia, Op. 116 No. 2", filename: "Classicals.de - Brahms - Fantasia, Opus 116 - No. 2 - Arranged for Strings", artist: "Brahms"),
        AudioTrack(title: "Mozart - Symphony in F major", filename: "Classicals.de - Mozart - Symphony in F major, K.Anh.223:19a - III", artist: "Mozart"),
        AudioTrack(title: "Vivaldi - Oboe Concerto", filename: "Classicals.de - Vivaldi - Oboe Concerto in C major - 2. Larghetto - RV 447", artist: "Vivaldi"),
        AudioTrack(title: "Vivaldi - Spring", filename: "Vivaldi - Spring", artist: "Vivaldi"),
    ]
    @Published var selectedTrackIndex: Int = 0

    public var selectedTrack: AudioTrack {
        availableTracks[selectedTrackIndex]
    }

    override init() {
        super.init()
        setupEngine()
        loadNoiseBuffer()
        loadBeepBuffer()
        loadHeterodyneBuffer()
        preloadUISounds()
        
        // Prepare haptics
        lightHaptic.prepare()
        mediumHaptic.prepare()
        
        debugListBundleResources()
    }
    
    private func preloadUISounds() {
        let sounds = ["button-click", "button-release", "volume-tick-1"]
        let bundle: Bundle = {
            #if SWIFT_PACKAGE
            return Bundle.module
            #else
            return Bundle.main
            #endif
        }()
        
        for name in sounds {
            if let url = bundle.url(forResource: name, withExtension: "mp3") ??
                         bundle.url(forResource: name, withExtension: "mp3", subdirectory: "Resources"),
               let data = try? Data(contentsOf: url) {
                cachedSoundData[name] = data
            }
        }
    }

    private func setupEngine() {
        // Configure audio session once for playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            print("❌ Failed to setup audio session: \(error)")
        }

        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(distortionNode)
        engine.attach(delayNode)
        engine.attach(noisePlayerNode)
        engine.attach(beepPlayerNode)
        engine.attach(heterodynePlayerNode)
        engine.attach(mixerNode)

        let format = engine.mainMixerNode.outputFormat(forBus: 0)

        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: distortionNode, format: format)
        engine.connect(distortionNode, to: delayNode, format: format)
        engine.connect(delayNode, to: mixerNode, format: format)

        engine.connect(noisePlayerNode, to: mixerNode, format: format)
        engine.connect(beepPlayerNode, to: mixerNode, format: format)
        engine.connect(heterodynePlayerNode, to: mixerNode, format: format)

        engine.connect(mixerNode, to: engine.mainMixerNode, format: format)

        prepareFilter(currentFilter)
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func startMonitoring() {
        // Keep monitoring path as-is but stop via queue
        stopPlayback()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            if engine.isRunning {
                engine.stop()
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)

            engine.disconnectNodeInput(eqNode)
            engine.disconnectNodeInput(distortionNode)
            engine.disconnectNodeInput(delayNode)
            engine.disconnectNodeInput(mixerNode)

            engine.connect(inputNode, to: eqNode, format: inputFormat)
            engine.connect(eqNode, to: distortionNode, format: inputFormat)
            engine.connect(distortionNode, to: delayNode, format: inputFormat)
            engine.connect(delayNode, to: mixerNode, format: inputFormat)
            engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)

            engine.prepare()
            try engine.start()
            isMonitoring = true

            if let buffer = noiseBuffer {
                noisePlayerNode.volume = (currentFilter == .hamRadio) ? 0.08 : 0.03
                noisePlayerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                noisePlayerNode.play()

                if currentFilter == .hamRadio {
                    startHeterodyne()
                }
            }
        } catch {
            print("Could not start engine for monitoring: \(error)")
        }
    }

    func stopMonitoring() {
        // ensure no race with playback
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.engine.stop()

            self.engine.disconnectNodeInput(self.eqNode)
            self.engine.disconnectNodeInput(self.distortionNode)
            self.engine.disconnectNodeInput(self.delayNode)
            self.engine.disconnectNodeInput(self.mixerNode)

            let outputFormat = self.engine.mainMixerNode.outputFormat(forBus: 0)

            self.engine.connect(self.playerNode, to: self.eqNode, format: outputFormat)
            self.engine.connect(self.eqNode, to: self.distortionNode, format: outputFormat)
            self.engine.connect(self.distortionNode, to: self.delayNode, format: outputFormat)
            self.engine.connect(self.delayNode, to: self.mixerNode, format: outputFormat)
            self.engine.connect(self.mixerNode, to: self.engine.mainMixerNode, format: outputFormat)

            self.noisePlayerNode.stop()
            self.stopHeterodyne()

            Task { @MainActor in
                self.isMonitoring = false
            }
        }
    }



    private func loadNoiseBuffer() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let frameCount = AVAudioFrameCount(format.sampleRate * 5.0)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        let channelCount = Int(buffer.format.channelCount)

        for channel in 0..<channelCount {
            if let data = buffer.floatChannelData?[channel] {
                for i in 0..<Int(frameCount) {
                    let whiteNoise = Float.random(in: -1.0...1.0) * 0.4
                    let rumble = sin(Float(i) * 0.01) * 0.1
                    data[i] = whiteNoise + rumble
                }
            }
        }
        self.noiseBuffer = buffer
    }

    private func loadBeepBuffer() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let duration: Double = 0.2
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        let channelCount = Int(buffer.format.channelCount)
        let frequency: Float = 1200.0
        let k: Float = 10.0 // Decay constant

        for channel in 0..<channelCount {
            if let data = buffer.floatChannelData?[channel] {
                for i in 0..<Int(frameCount) {
                    let t = Float(i) / Float(format.sampleRate)
                    let envelope = exp(-k * t)
                    data[i] = envelope * sin(2.0 * .pi * frequency * t) * 0.4
                }
            }
        }
        self.beepBuffer = buffer
    }

    private func loadHeterodyneBuffer() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let duration: Double = 5.0
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount
        let channelCount = Int(buffer.format.channelCount)

        for channel in 0..<channelCount {
            if let data = buffer.floatChannelData?[channel] {
                var phase: Float = 0
                for i in 0..<Int(frameCount) {
                    let t = Float(i) / Float(format.sampleRate)
                    let baseFreq: Float = 1000.0
                    let driftFreq = baseFreq + sin(2.0 * .pi * 0.2 * t) * 200.0
                    phase += 2.0 * .pi * driftFreq / Float(format.sampleRate)
                    data[i] = sin(phase) * 0.05
                }
            }
        }
        self.heterodyneBuffer = buffer
    }

    private func playRogerBeep() {
        guard let buffer = beepBuffer else { return }
        beepPlayerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        beepPlayerNode.play()
    }

    private func playSquelchStart() {
        guard let buffer = noiseBuffer else { return }
        noisePlayerNode.volume = 0.4
        noisePlayerNode.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        noisePlayerNode.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.noisePlayerNode.volume = 0.04
        }
    }

    private func playSquelchEnd() {
        noisePlayerNode.volume = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.noisePlayerNode.volume = 0.0
            self.noisePlayerNode.stop()
        }
    }

    public func setFilter(_ filter: RadioFilter) {
        currentFilter = filter
        prepareFilter(filter)
        if isMonitoring {
            if filter == .hamRadio {
                startHeterodyne()
            } else {
                stopHeterodyne()
            }
        }
    }

    private func startHeterodyne() {
        guard let buffer = heterodyneBuffer else { return }
        heterodynePlayerNode.volume = 0.1
        heterodynePlayerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        heterodynePlayerNode.play()
    }

    private func stopHeterodyne() {
        heterodynePlayerNode.stop()
    }

    private func prepareFilter(_ filter: RadioFilter) {
        distortionNode.bypass = true
        delayNode.bypass = true
        for i in 0..<3 { eqNode.bands[i].bypass = true }

        switch filter {
        case .amRadio:
            eqNode.bands[0].filterType = .highPass
            eqNode.bands[0].frequency = 300
            eqNode.bands[0].bypass = false
            eqNode.bands[1].filterType = .lowPass
            eqNode.bands[1].frequency = 3000
            eqNode.bands[1].bypass = false
            distortionNode.loadFactoryPreset(.multiBrokenSpeaker)
            distortionNode.preGain = -5
            distortionNode.wetDryMix = 20
            distortionNode.bypass = false
        case .fmVintage:
            eqNode.bands[0].filterType = .parametric
            eqNode.bands[0].frequency = 500
            eqNode.bands[0].gain = 6
            eqNode.bands[0].bypass = false
            distortionNode.loadFactoryPreset(.multiDistortedSquared)
            distortionNode.wetDryMix = 15
            distortionNode.bypass = false
        case .hamRadio:
            eqNode.bands[0].filterType = .highPass
            eqNode.bands[0].frequency = 500
            eqNode.bands[0].bypass = false
            eqNode.bands[1].filterType = .lowPass
            eqNode.bands[1].frequency = 2200
            eqNode.bands[1].bypass = false
            delayNode.delayTime = 0.02
            delayNode.feedback = 40
            delayNode.wetDryMix = 30
            delayNode.bypass = false
        }
    }

    // MARK: - Public playback API (debounced & queued)

    public func playTrack(at index: Int, autoPlay: Bool = true) {
        let now = Date()
        guard now.timeIntervalSince(lastTrackChangeTime) >= minTrackChangeInterval else {
            return
        }
        lastTrackChangeTime = now

        audioQueue.async { [weak self] in
            guard let self else { return }
            let safeIndex = max(0, min(self.availableTracks.count - 1, index))

            Task { @MainActor in
                self.selectedTrackIndex = safeIndex
            }

            if autoPlay {
                self.stopPlaybackInternal()
                self.playTestAudioInternal()
            }
        }
    }

    public func playTestAudio() {
        audioQueue.async { [weak self] in
            self?.playTestAudioInternal()
        }
    }

    // MARK: - Internal playback helpers (called only on audioQueue)

    private func playTestAudioInternal() {
        if isPaused {
            resumePlaybackInternal()
            return
        }

        guard let url = getTestAudioURL() else {
            print("❌ Test audio file not found")
            return
        }

        playAudioInternal(at: url)
    }

    private func playAudioInternal(at url: URL) {
        do {
            let session = AVAudioSession.sharedInstance()
            // Category is already set in setupEngine; ensure active
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)

            if isMonitoring {
                stopMonitoringInternal()
            }

            let file = try AVAudioFile(forReading: url)
            if !engine.isRunning {
                try engine.start()
            }

            playerNode.stop()
            playerNode.reset()
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                Task { @MainActor in
                    self?.isPlaying = false
                }
            }
            playerNode.play()

            Task { @MainActor in
                self.isPlaying = true
                self.isPaused = false
            }

            print("▶️ Playing: \(url.lastPathComponent)")
        } catch {
            print("Error playing audio: \(error)")
        }
    }

    private func stopMonitoringInternal() {
        engine.stop()
        engine.disconnectNodeInput(eqNode)
        engine.disconnectNodeInput(distortionNode)
        engine.disconnectNodeInput(delayNode)
        engine.disconnectNodeInput(mixerNode)

        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: eqNode, format: outputFormat)
        engine.connect(eqNode, to: distortionNode, format: outputFormat)
        engine.connect(distortionNode, to: delayNode, format: outputFormat)
        engine.connect(delayNode, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)

        noisePlayerNode.stop()
        stopHeterodyne()

        Task { @MainActor in
            self.isMonitoring = false
        }
    }

    private func getTestAudioURL() -> URL? {
        let bundle: Bundle = {
#if SWIFT_PACKAGE
            return Bundle.module
#else
            return Bundle.main
#endif
        }()

        let filename = selectedTrack.filename
        return bundle.url(forResource: filename, withExtension: "mp3") ??
        bundle.url(forResource: filename, withExtension: "mp3", subdirectory: "Resources") ??
        bundle.url(forResource: filename, withExtension: "mp3", subdirectory: "Sounds")
    }

    private func debugListBundleResources() {
        let bundle: Bundle = {
#if SWIFT_PACKAGE
            return Bundle.module
#else
            return Bundle.main
#endif
        }()

        print("📦 Bundle URL:", bundle.bundleURL)

        if let resourcesURL = bundle.resourceURL,
           let files = try? FileManager.default.contentsOfDirectory(
            at: resourcesURL,
            includingPropertiesForKeys: nil
           ) {
            print("📂 Resources folder contents:")
            for url in files {
                print(" -", url.lastPathComponent)
            }
        } else {
            print("⚠️ Could not list bundle resources")
        }
    }

    // MARK: - Public stop/pause/resume (queued)

    public func pausePlayback() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if self.isPlaying {
                self.playerNode.pause()
                self.noisePlayerNode.pause()
                Task { @MainActor in
                    self.isPlaying = false
                    self.isPaused = true
                }
            }
        }
    }

    public func resumePlayback() {
        audioQueue.async { [weak self] in
            self?.resumePlaybackInternal()
        }
    }

    private func resumePlaybackInternal() {
        if isPaused {
            playerNode.play()
            noisePlayerNode.play()
            Task { @MainActor in
                self.isPlaying = true
                self.isPaused = false
            }
        }
    }

    public func stopPlayback() {
        audioQueue.async { [weak self] in
            self?.stopPlaybackInternal()
        }
    }

    private func stopPlaybackInternal() {
        playerNode.stop()
        noisePlayerNode.stop()
        Task { @MainActor in
            self.isPlaying = false
            self.isPaused = false
        }
    }

    public func playSound(_ name: String, rate: Float? = nil) {
        // Prepare the player immediately on the calling thread
        let player: AVAudioPlayer? = {
            do {
                if let data = self.cachedSoundData[name] {
                    return try AVAudioPlayer(data: data)
                } else {
                    let bundle: Bundle = {
#if SWIFT_PACKAGE
                        return Bundle.module
#else
                        return Bundle.main
#endif
                    }()
                    guard let url = bundle.url(forResource: name, withExtension: "mp3") ??
                            bundle.url(forResource: name, withExtension: "mp3", subdirectory: "Resources") else {
                        return nil
                    }
                    return try AVAudioPlayer(contentsOf: url)
                }
            } catch {
                print("❌ Error initializing player: \(error)")
                return nil
            }
        }()

        guard let player = player else { return }
        player.prepareToPlay()

        Task { @MainActor in
            self.tickLock.lock()
            defer { self.tickLock.unlock() }
            
            // Clean up old finished players
            self.activeTickPlayers.removeAll { !$0.isPlaying }

            if name.contains("tick") {
                // Throttle tick sounds if too many are playing
                guard self.activeTickPlayers.count < self.maxTickPlayers else { return }
                
                player.volume = 0.3
                player.enableRate = true
                player.rate = rate ?? 1.0
                self.activeTickPlayers.append(player)
                player.play()
            } else {
                self.uiSoundPlayer = player
                self.uiSoundPlayer?.play()
            }
        }
    }

    public func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        switch style {
        case .light:
            lightHaptic.impactOccurred()
        case .medium:
            mediumHaptic.impactOccurred()
        default:
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred()
        }
    }
}
public struct ContentView: View {
    @StateObject private var audioManager = RadioAudioManager.shared
    @State private var isPlayToggled = false
    @State private var startVolume: Double = 0
    @State private var lastAngle: Double = 0
    @State private var angleOffset: Double = 0


    let volumeSteps = 32

    public init() {}

    public var body: some View {
        ZStack {
            Color(red: 0xF7/255, green: 0xF7/255, blue: 0xF6/255)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Speaker Image
                Image("speaker")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 320)
                    .padding(.top, 25)

                // Display with Song List
                ZStack {
                    Image("display_on")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 350)

                    VStack {
                        HStack {
                            Text("Music")
                                .font(.custom("LED Dot-Matrix", size: 14))

                            Spacer()

                            Text("FM")
                                .font(.custom("LED Dot-Matrix", size: 14))
                        }
                        .padding(.bottom, 5)

                        // Track List Overlay
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visibleTracks) { track in
                                Button(action: {
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        if let idx = audioManager.availableTracks.firstIndex(of: track) {
                                            audioManager.playTrack(at: idx)
                                        }
                                    }
                                }) {
                                    HStack(alignment: .top, spacing: 5) {
                                        Text(audioManager.selectedTrack == track ? ">" : "-")
                                            .font(.custom("LED Dot-Matrix", size: 14))
                                            .foregroundColor(audioManager.selectedTrack == track ? .black : .black.opacity(0.2))
                                            .padding(.leading, audioManager.selectedTrack == track ? 5 : 0)

                                        Text(track.title.uppercased())
                                            .font(.custom("LED Dot-Matrix", size: 14))
                                            .foregroundColor(audioManager.selectedTrack == track ? .black : .black.opacity(0.2))
                                            .lineLimit(1)
                                    }
                                }
                                .buttonStyle(PlainNoAnimationButtonStyle())
                            }
                        }
                        .animation(nil, value: audioManager.selectedTrackIndex)
                        .transaction { transaction in
                            transaction.disablesAnimations = true
                        }
                        .padding(.horizontal, 40)
                        .frame(width: 300, alignment: .leading)
                    }
                    .animation(nil, value: audioManager.selectedTrackIndex)
                    // Position to match screen in the PNG
                    .frame(width: 260, height: 140) // screen size
                    // move into screen area

                    // Prevent UI from leaking outside screen
                    .clipped()
                }


                // Volume Control (Left Aligned above buttons)
                HStack {
                    VStack(spacing: 5) {
                        ZStack {
                            Image("volume_indicator_line")
                                .resizable()
                                .scaledToFit()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 142, height: 120)
                                .offset(x: -1, y: -18)

                            ZStack {
                                // Shadow (static, bottom layer)
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            stops: [
                                                .init(color: .black, location: 0.31),
                                                .init(color: Color(red: 0.67, green: 0.67, blue: 0.67), location: 1.0)
                                            ],
                                            startPoint: UnitPoint(x: 0.82, y: 1.18),
                                            endPoint: UnitPoint(x: 0.25, y: 0.2)
                                        )
                                    )
                                    .frame(width: 112.5, height: 112.5)
                                    .shadow(color: .black.opacity(0.2), radius: 2.4, x: 5, y: 7)
                                    .shadow(color: .black.opacity(0.76), radius: 2.45, x: 1, y: 2)

                                Image("knob_black_ring")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 116)

                                // Control knob (rotates)
                                Image("knob_control")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 116)
                                    .rotationEffect(.degrees(audioManager.volume * 240 - 120))
                                    .animation(nil, value: audioManager.volume)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let center = CGPoint(x: 58, y: 58)
                                                let currentVector = CGVector(dx: value.location.x - center.x, dy: value.location.y - center.y)
                                                let currentAngle = atan2(currentVector.dy, currentVector.dx)

                                                // Convert radians to degrees and align with SwiftUI's rotation (0 is up)
                                                var currentDeg = Double(currentAngle) * 180.0 / .pi + 90.0
                                                if currentDeg > 180 { currentDeg -= 360 }
                                                if currentDeg < -180 { currentDeg += 360 }

                                                if value.startLocation == value.location {
                                                    // Calculate the difference between finger angle and knob angle
                                                    let initialKnobDeg = audioManager.volume * 240.0 - 120.0
                                                    angleOffset = currentDeg - initialKnobDeg
                                                }

                                                var targetDeg = currentDeg - angleOffset

                                                // Normalize targetDeg to stay within a reasonable range around the knob's arc
                                                if targetDeg > 180 { targetDeg -= 360 }
                                                if targetDeg < -180 { targetDeg += 360 }

                                                // Map -120...120 degrees to 0...1 volume
                                                let newVolume = quantize(max(0, min(1, (targetDeg + 120.0) / 240.0)))

                                                if newVolume != audioManager.volume {
                                                    audioManager.triggerHaptic(.light)

                                                    let calculatedRate = Float(0.7 + (newVolume * 1.0))
                                                    audioManager.playSound("volume-tick-1", rate: calculatedRate)

                                                    audioManager.volume = newVolume
                                                }
                                            }
                                    )
                            }
                        }

                        Text("VOLUME")
                            .font(.custom("LED Dot-Matrix", size: 10))
                            .foregroundColor(.black.opacity(0.5))
                    }
                    .padding(.leading, 30)
                    Spacer()
                }

                                                                // Playback Controls (Bottom Row)
                                                                HStack(spacing: 5) {
                                                                    controlButton(icon: "ic_replay", isActive: false, altIcon: nil) {
                                                                        audioManager.triggerHaptic(.light)
                                                                        audioManager.playSound("button-click")
                                                                        audioManager.stopPlayback()
                                                                        audioManager.playTestAudio()
                                                                    }
                                                                    
                                                                    controlButton(icon: "ic_previous", isActive: false, altIcon: nil) {
                                                                        audioManager.triggerHaptic(.light)
                                                                        audioManager.playSound("button-click")
                                                                        var transaction = Transaction()
                                                                        transaction.disablesAnimations = true
                                                                        withTransaction(transaction) {
                                                                            let prevIndex = (audioManager.selectedTrackIndex - 1 + audioManager.availableTracks.count) % audioManager.availableTracks.count
                                                                            audioManager.playTrack(at: prevIndex, autoPlay: audioManager.isPlaying)
                                                                        }
                                                                    }
                                                                    
                                                                                        controlButton(
                                                                                            icon: isPlayToggled ? "ic_pause" : "ic_play",
                                                                                            background: "button_enable",
                                                                                            isActive: isPlayToggled,
                                                                                            altIcon: isPlayToggled ? "ic_play" : "ic_pause"
                                                                                        ) {
                                                                                            var transaction = Transaction()
                                                                                            transaction.disablesAnimations = true
                                                                                            withTransaction(transaction) {
                                                                                                audioManager.triggerHaptic(.light)
                                                                                                if isPlayToggled {
                                                                                                    audioManager.playSound("button-click")
                                                                                                    audioManager.stopPlayback()
                                                                                                    isPlayToggled = false
                                                                                                } else {
                                                                                                    audioManager.playSound("button-release")
                                                                                                    audioManager.playTestAudio()
                                                                                                    isPlayToggled = true
                                                                                                }
                                                                                            }
                                                                                        }                                                                    
                                                                    controlButton(icon: "ic_next", isActive: false, altIcon: nil) {
                                                                        audioManager.triggerHaptic(.light)
                                                                        audioManager.playSound("button-click")
                                                                        var transaction = Transaction()
                                                                        transaction.disablesAnimations = true
                                                                        withTransaction(transaction) {
                                                                            let nextIndex = (audioManager.selectedTrackIndex + 1) % audioManager.availableTracks.count
                                                                            audioManager.playTrack(at: nextIndex, autoPlay: audioManager.isPlaying)
                                                                        }
                                                                    }
                                                                    
                                                                    controlButton(icon: "ic_stop", isActive: false, altIcon: nil) {
                                                                        audioManager.triggerHaptic(.light)
                                                                        audioManager.playSound("button-click")
                                                                        audioManager.stopPlayback()
                                                                        isPlayToggled = false
                                                                    }
                                                                }                .padding(.vertical, 3)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(hex: "191818"))
                )
                .padding(.bottom, 40)
            }
        }
    }

    // Helper for styled control buttons (uniform size)
            private func controlButton(
                icon: String,
                background: String = "button_enable",
                isActive: Bool = false,
                altIcon: String? = nil,
                size: CGFloat = 65,
                action: @escaping () -> Void
            ) -> some View {
                
                Button(action: action) {
                    ZStack {
                        // The background is now managed by the ButtonStyle configuration

                        Image(icon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size * 0.35, height: size * 0.35)
                            .animation(nil, value: icon)
                    }
                    .frame(width: size, height: size * 0.6)
                }
                .buttonStyle(NoAnimationButtonStyle(baseBackground: background, isActive: isActive, altIcon: altIcon, size: size)) 
            }    // Logic to show only 3 tracks around the selected one
    private var visibleTracks: [AudioTrack] {
        let count = audioManager.availableTracks.count
        if count == 0 { return [] }

        let current = audioManager.selectedTrackIndex

        // Show previous, current, and next
        let prev = (current - 1 + count) % count
        let next = (current + 1) % count

        return [
            audioManager.availableTracks[prev],
            audioManager.availableTracks[current],
            audioManager.availableTracks[next]
        ]
    }

    func quantize(_ value: Double) -> Double {
        let step = 1.0 / Double(volumeSteps - 1)
        return (value / step).rounded() * step
    }
}

struct NoAnimationButtonStyle: ButtonStyle {
    let baseBackground: String
    let isActive: Bool
    let altIcon: String?
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            // Show disable if pressed OR if it's the active toggled state
            Image((configuration.isPressed || isActive) ? "button_disable" : baseBackground)
                .resizable()
                .frame(width: size, height: size * 0.6)
                .animation(nil, value: configuration.isPressed || isActive)
            
            if configuration.isPressed, let alt = altIcon {
                Image(alt)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.35, height: size * 0.35)
            } else {
                configuration.label
            }
        }
    }
}
struct PlainNoAnimationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(nil, value: configuration.isPressed)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255

        self.init(red: r, green: g, blue: b)
    }
}
