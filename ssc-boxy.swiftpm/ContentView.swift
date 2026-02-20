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
    
    public var frequency: String {
        switch self {
        case .amRadio: return "540 AM"
        case .fmVintage: return "101.5 FM"
        case .hamRadio: return "14.250 MHz"
        }
    }
    
    public var description: String {
        switch self {
        case .amRadio: return "1930s Narrowband"
        case .fmVintage: return "70s Warm Broadcast"
        case .hamRadio: return "Global Shortwave"
        }
    }
}

@MainActor
public class RadioAudioManager: NSObject, ObservableObject {
    public static let shared = RadioAudioManager()
    
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
    
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var isMonitoring = false
    @Published var isAutoEchoEnabled = false
    @Published var currentFilter: RadioFilter = .amRadio
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
    }
    
    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(eqNode)
        engine.attach(distortionNode)
        engine.attach(delayNode)
        engine.attach(noisePlayerNode)
        engine.attach(beepPlayerNode)
        engine.attach(heterodynePlayerNode)
        engine.attach(mixerNode)
        
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        
        // Connect player -> EQ -> Distortion -> Delay -> Mixer
        engine.connect(playerNode, to: eqNode, format: format)
        engine.connect(eqNode, to: distortionNode, format: format)
        engine.connect(distortionNode, to: delayNode, format: format)
        engine.connect(delayNode, to: mixerNode, format: format)
        
        // Connect noise, beep and heterodyne to mixer
        engine.connect(noisePlayerNode, to: mixerNode, format: format)
        engine.connect(beepPlayerNode, to: mixerNode, format: format)
        engine.connect(heterodynePlayerNode, to: mixerNode, format: format)
        
        // Connect mixer to output
        engine.connect(mixerNode, to: engine.mainMixerNode, format: format)
        
        prepareFilter(.amRadio)
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func startMonitoring() {
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
            
            // Rebuild chain: Input -> EQ -> Distortion -> Delay -> Mixer
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
        engine.stop()
        
        // Reset the chain back to the playerNode
        engine.disconnectNodeInput(eqNode)
        engine.disconnectNodeInput(distortionNode)
        engine.disconnectNodeInput(delayNode)
        engine.disconnectNodeInput(mixerNode)
        
        let outputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        
        // Rebuild chain for playback: Player -> EQ -> Distortion -> Delay -> Mixer
        engine.connect(playerNode, to: eqNode, format: outputFormat)
        engine.connect(eqNode, to: distortionNode, format: outputFormat)
        engine.connect(distortionNode, to: delayNode, format: outputFormat)
        engine.connect(delayNode, to: mixerNode, format: outputFormat)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: outputFormat)
        
        isMonitoring = false
        noisePlayerNode.stop()
        stopHeterodyne()
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
    
    public func playTrack(at index: Int) {
        selectedTrackIndex = index
        stopPlayback()
        playTestAudio()
    }

    public func playTestAudio() {
        if isPaused {
            resumePlayback()
            return
        }
        
        guard let url = getTestAudioURL() else {
            print("❌ Test audio file not found")
            return
        }
        
        playAudio(at: url, isLocal: false)
    }
    
    private func getTestAudioURL() -> URL? {
        let filename = selectedTrack.filename
        return Bundle.main.url(forResource: filename, withExtension: "mp3") ?? 
               Bundle.main.url(forResource: filename, withExtension: "mp3", subdirectory: "Sounds")
    }
    
    private func playAudio(at url: URL, isLocal: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .defaultToSpeaker)
            try session.setActive(true)
            
            if isMonitoring { stopMonitoring() }
            
            let file = try AVAudioFile(forReading: url)
            if !engine.isRunning { try engine.start() }
            
            playerNode.stop()
            playerNode.scheduleFile(file, at: nil, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.isPlaying = false
                }
            })
            playerNode.play()
            isPlaying = true
            isPaused = false
            print("▶️ Playing: \(url.lastPathComponent)")
        } catch {
            print("Error playing audio: \(error)")
        }
    }

    public func pausePlayback() {
        if isPlaying {
            playerNode.pause()
            noisePlayerNode.pause()
            isPlaying = false
            isPaused = true
        }
    }

    public func resumePlayback() {
        if isPaused {
            playerNode.play()
            noisePlayerNode.play()
            isPlaying = true
            isPaused = false
        }
    }

    public func stopPlayback() {
        playerNode.stop()
        noisePlayerNode.stop()
        isPlaying = false
        isPaused = false
    }
}

public struct ContentView: View {
    @StateObject private var audioManager = RadioAudioManager.shared
    @State private var isPlayToggled = false
    
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
                    .frame(height: 400) // Increased from 140
                    .padding(.top, 20)
                
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
                                    if let idx = audioManager.availableTracks.firstIndex(of: track) {
                                        audioManager.playTrack(at: idx)
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
                            }
                        }
                        .padding(.horizontal, 40)
                        .frame(width: 300, alignment: .leading)
                    }
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
                                .frame(width: 139.76) // Set precisely to 139.76
                                .padding(.bottom, 40)
                                .offset(x: -1)
                            
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
                                
                                // Control knob (rotates)
                                Image("knob_control")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 116)
                                    .rotationEffect(.degrees(audioManager.volume * 240 - 120))
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                let delta = -Double(value.translation.height) / 200.0
                                                audioManager.volume = max(0, min(1, audioManager.volume + delta))
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
                    controlButton(icon: "ic_replay") {
                        audioManager.stopPlayback()
                        audioManager.playTestAudio()
                    }
                    
                    controlButton(icon: "ic_previous") {
                        let prevIndex = (audioManager.selectedTrackIndex - 1 + audioManager.availableTracks.count) % audioManager.availableTracks.count
                        audioManager.playTrack(at: prevIndex)                        }
                    
                    controlButton(
                        icon: isPlayToggled ? "ic_pause" : "ic_play",
                        background: isPlayToggled ? "button_disable" : "button_enable"
                    ) {
                        if isPlayToggled {
                            audioManager.stopPlayback()
                            isPlayToggled = false
                        } else {
                            audioManager.playTestAudio()
                            isPlayToggled = true
                        }
                    }
                    
                    controlButton(icon: "ic_next") {
                        let nextIndex = (audioManager.selectedTrackIndex + 1) % audioManager.availableTracks.count
                        audioManager.playTrack(at: nextIndex)
                    }
                    
                    controlButton(icon: "ic_stop") {
                        audioManager.stopPlayback()
                        isPlayToggled = false
                    }
                }
                .padding(.vertical, 3)
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
        size: CGFloat = 65,
        action: @escaping () -> Void
    ) -> some View {
        
        Button(action: action) {
            ZStack {
                Image(background)
                    .resizable()
                    .frame(width: size, height: size * 0.6)
                
                Image(icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.35, height: size * 0.35)
            }
        }
        .buttonStyle(.plain) 
    }
    
    // Logic to show only 3 tracks around the selected one
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
