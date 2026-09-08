// Compiled into the iOS receiver and the Mac receiver (see project.yml
// `sources`). Everything here must exist on the RECEIVER's deployment target,
// which is several majors below the sender's — CI builds the receiver app to
// catch a newer API sneaking in.

import AVFoundation
import Foundation

/// A snapshot of the audio path's health, for the overlay and the wire report.
struct AudioStats {
    var depth = 0          // packets held right now
    var target = 0         // pre-roll depth, which adapts upward on underruns
    var underruns = 0
    var dropped = 0
    var reordered = 0
    var adaptations = 0    // times the target grew this session
}

/// Decodes AAC audio packets and plays them.
///
/// Feeding is decoupled from playback by a jitter buffer: packets arrive in
/// network bursts, the engine consumes them at a fixed rate. A drain timer
/// moves packets between the two, so a late packet costs latency rather than
/// a gap.
///
/// Every failure here is non-fatal by construction. Audio is an optional
/// addition to a display, and a device that cannot decode it must still show
/// the picture.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Serialises the buffer and the engine; packets arrive on the network
    /// queue and the drain timer fires on its own.
    private let queue = DispatchQueue(label: "receiver.audio")
    private var buffer = AudioJitterBuffer()
    private var drainTimer: DispatchSourceTimer?
    private var running = false
    private var loggedFormat = false
    private var loggedStartFailure = false

    /// User-facing mute. Packets keep flowing and the buffer keeps draining —
    /// muting only silences output, so unmuting resumes in sync instead of
    /// playing a backlog.
    var isMuted = false

    // MARK: - Lifecycle

    /// Prepare the engine. Safe to call repeatedly.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.buffer.reset()
            self.startDrainTimer()
        }
    }

    /// Start a new session: drop held audio and forget the buffer depth
    /// learned from the previous peer, which may have been on a different
    /// network entirely.
    func startNewSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.resetForNewSession()
        }
        start()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.drainTimer?.cancel()
            self.drainTimer = nil
            self.player.stop()
            if self.engine.isRunning { self.engine.stop() }
            self.buffer.reset()
            self.converter = nil
            self.sourceFormat = nil
            self.loggedFormat = false
        }
    }

    /// Drop buffered audio without tearing the engine down — for a new session
    /// or a resume, where held packets are stale.
    func flush() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.reset()
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
        }
    }

    // MARK: - Feeding

    func enqueue(_ packet: AudioPacket) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.buffer.enqueue(packet)
        }
    }

    /// Counters for the stats report, and the current buffer depth.
    ///
    /// Consuming: the counters are zeroed, so each reported figure covers the
    /// interval since the last call. Use `peekStats` for anything that reads
    /// more often, or it will starve this of counts.
    func drainStats() -> AudioStats {
        queue.sync {
            let stats = currentStats
            buffer.resetCounters()
            return stats
        }
    }

    /// The same figures without clearing them — for the live overlay, which
    /// samples every second while the wire report drains every five.
    func peekStats() -> AudioStats {
        queue.sync { currentStats }
    }

    private var currentStats: AudioStats {
        AudioStats(depth: buffer.depth,
                   target: buffer.targetDepth,
                   underruns: buffer.underruns,
                   dropped: buffer.dropped,
                   reordered: buffer.reordered,
                   adaptations: buffer.adaptations)
    }

    // MARK: - Playback

    /// Move packets from the buffer into the engine.
    ///
    /// A timer rather than a pull callback: `scheduleBuffer` is push-driven, so
    /// something has to decide when to push. The interval is shorter than one
    /// AAC packet's duration (~21ms at 48kHz) so the engine is topped up before
    /// it drains rather than after.
    private func startDrainTimer() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        guard running else { return }
        // Bounded per tick: after a stall the buffer may hold many packets, and
        // scheduling all of them at once would hand the engine a burst it plays
        // as fast as it can. Two per 10ms tick outruns real-time (~21ms per
        // packet) enough to recover without racing.
        for _ in 0..<2 {
            guard let packet = buffer.dequeue() else { return }
            play(packet)
        }
    }

    private func play(_ packet: AudioPacket) {
        guard let pcm = decode(packet) else { return }
        guard ensureEngineRunning(for: pcm.format) else { return }
        if isMuted { return }   // decoded and dequeued, just not heard
        player.scheduleBuffer(pcm, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Decoding

    private func decode(_ packet: AudioPacket) -> AVAudioPCMBuffer? {
        guard let converter = converter(for: packet),
              let outputFormat else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.payload.count, 1))
        compressed.byteLength = UInt32(packet.payload.count)
        compressed.packetCount = 1
        packet.payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            compressed.data.copyMemory(from: base, byteCount: packet.payload.count)
        }
        // AAC-LC is 1024 samples per packet; the description tells the decoder
        // how much of `data` this packet occupies.
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.payload.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                         frameCapacity: 2048) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }

        switch status {
        case .haveData:
            return pcm.frameLength > 0 ? pcm : nil
        case .inputRanDry, .endOfStream:
            return nil
        case .error:
            if let error { Log.info("audio decode error: \(error)") }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Build (or reuse) the decoder for this packet's format.
    private func converter(for packet: AudioPacket) -> AVAudioConverter? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(packet.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(packet.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &description) else { return nil }

        if let converter, let sourceFormat, sourceFormat == inFormat { return converter }

        // Float32 deinterleaved is what AVAudioEngine wants; letting it convert
        // again downstream would be a second resample for nothing.
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: Double(packet.sampleRate),
                                            channels: AVAudioChannelCount(packet.channels)),
              let made = AVAudioConverter(from: inFormat, to: outFormat) else {
            Log.info("audio: no decoder for \(packet.sampleRate)Hz \(packet.channels)ch")
            return nil
        }

        converter = made
        sourceFormat = inFormat
        outputFormat = outFormat
        if !loggedFormat {
            loggedFormat = true
            Log.info("audio: decoding \(packet.sampleRate)Hz \(packet.channels)ch")
        }
        // The graph is wired for the old format; rebuild it for this one.
        teardownGraph()
        return made
    }

    // MARK: - Engine

    private func ensureEngineRunning(for format: AVAudioFormat) -> Bool {
        if engine.isRunning, player.engine != nil { return true }

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            loggedStartFailure = false
            return true
        } catch {
            // Log once: this is called per packet, and a device that refuses to
            // start the engine refuses every time.
            if !loggedStartFailure {
                loggedStartFailure = true
                Log.info("audio: engine would not start (\(error)) — no playback")
            }
            return false
        }
    }

    private func teardownGraph() {
        player.stop()
        if engine.isRunning { engine.stop() }
        if player.engine != nil { engine.disconnectNodeOutput(player) }
    }
}
