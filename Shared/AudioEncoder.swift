import AVFoundation
import Foundation

/// PCM → AAC-LC for the audio channel, kept out of the senders so they stay
/// about streaming and this stays about codecs.
///
/// Shared by both capture sources: ScreenCaptureKit on the Mac and ReplayKit
/// in the iOS broadcast extension. Both hand over PCM in whatever chunk size
/// they please, which is why this accumulates whole 1024-sample frames rather
/// than converting each buffer as it arrives (see `append`).
///
/// Fixed bitrate: audio is ~1% of video's bandwidth, so there is nothing to
/// gain from adapting it to the quality setting the way the video encoder
/// does — one less thing to get wrong.
///
/// AVFoundation-only by design. The broadcast extension runs in a ~50 MB
/// process, and the Mac receiver builds at a much older deployment target
/// than the sender, so nothing here may reach for a platform framework.
final class AudioEncoder {

    /// AAC-LC, 128 kbps stereo. Comfortably transparent for desktop audio and
    /// hardware-decodable on every receiver we target.
    private static let bitRate = 128_000

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    /// AAC's AudioSpecificConfig (the "magic cookie"). The decoder cannot start
    /// without it, and a receiver may connect mid-stream, so it is re-sent
    /// whenever the format changes rather than once at startup.
    private(set) var configData: Data?
    private var needsConfigFlag = true

    var sampleRate: Int { Int(outputFormat?.sampleRate ?? 0) }
    var channels: Int { Int(outputFormat?.channelCount ?? 0) }

    /// The format everything is normalised to before encoding: Float32,
    /// deinterleaved, at the source's rate and channel count.
    ///
    /// The two capture sources disagree. ScreenCaptureKit hands over
    /// deinterleaved Float32, which `floatChannelData` reads directly;
    /// ReplayKit hands over *interleaved Int16*, where `floatChannelData` is
    /// nil and the per-channel copy in `append` silently copies nothing — the
    /// encoder then saw no samples and returned nil for every buffer, so the
    /// iOS sender encoded audio all session and sent none of it. Converting
    /// up front means one path serves both.
    private func canonicalFormat(matching format: AVAudioFormat) -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                      channels: format.channelCount)
    }

    private var inputConverter: AVAudioConverter?
    private var inputConverterSource: AVAudioFormat?

    /// Convert `pcm` to the canonical format when it is not already there.
    private func normalise(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let canonical = canonicalFormat(matching: pcm.format) else { return nil }
        if pcm.format == canonical { return pcm }

        if inputConverter == nil || inputConverterSource != pcm.format {
            inputConverter = AVAudioConverter(from: pcm.format, to: canonical)
            inputConverterSource = pcm.format
        }
        guard let converter = inputConverter,
              let out = AVAudioPCMBuffer(pcmFormat: canonical,
                                         frameCapacity: pcm.frameLength) else { return nil }
        var error: NSError?
        var supplied = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }
        guard status == .haveData || status == .inputRanDry, out.frameLength > 0 else { return nil }
        return out
    }

    /// Build (or rebuild) the converter for `format`. Returns false if the
    /// format cannot be encoded, in which case the caller drops audio rather
    /// than sending something no receiver can read.
    @discardableResult
    func prepare(for format: AVAudioFormat) -> Bool {
        // Against the canonical format, not the raw input: the encoder is fed
        // normalised buffers, so building from an interleaved Int16
        // description would mismatch what it actually receives.
        guard let format = canonicalFormat(matching: format) else { return false }
        if let sourceFormat, sourceFormat == format, converter != nil { return true }

        var description = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,      // AAC-LC's fixed frame size
            mBytesPerFrame: 0,
            mChannelsPerFrame: format.channelCount,
            mBitsPerChannel: 0,
            mReserved: 0)

        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: format, to: output) else {
            Log.info("audio: no AAC converter for \(format.sampleRate)Hz \(format.channelCount)ch — audio disabled")
            self.converter = nil
            return false
        }
        converter.bitRate = Self.bitRate

        self.converter = converter
        self.sourceFormat = format
        self.outputFormat = output
        self.configData = converter.outputFormat.magicCookie
        self.pending = nil
        self.needsConfigFlag = true
        Log.info("audio: encoding \(Int(format.sampleRate))Hz \(format.channelCount)ch AAC-LC @ \(Self.bitRate / 1000)kbps")
        return true
    }

    /// AAC-LC's fixed frame size. The converter needs this many samples per
    /// channel before it can emit a real packet.
    private static let framesPerPacket: AVAudioFrameCount = 1024

    /// Samples carried over from previous chunks, waiting to complete a frame.
    private var pending: AVAudioPCMBuffer?

    /// Stage `pcm` and return exactly one AAC frame's worth of samples once
    /// enough have accumulated, or nil while still short.
    ///
    /// Any remainder past the frame boundary is kept for the next call, so no
    /// audio is dropped at chunk edges — a gap there would be an audible click.
    private func append(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = pcm.format
        let carried = pending?.frameLength ?? 0
        let total = carried + pcm.frameLength

        guard let combined = AVAudioPCMBuffer(pcmFormat: format,
                                              frameCapacity: total) else { return nil }
        combined.frameLength = total
        if let pending, carried > 0 { copy(pending, into: combined, at: 0, count: carried) }
        copy(pcm, into: combined, at: carried, count: pcm.frameLength)

        guard total >= Self.framesPerPacket else {
            pending = combined          // still short — carry it all forward
            return nil
        }

        guard let frame = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: Self.framesPerPacket) else { return nil }
        frame.frameLength = Self.framesPerPacket
        copy(combined, into: frame, at: 0, count: Self.framesPerPacket, sourceOffset: 0)

        let leftover = total - Self.framesPerPacket
        if leftover > 0, let rest = AVAudioPCMBuffer(pcmFormat: format,
                                                     frameCapacity: leftover) {
            rest.frameLength = leftover
            copy(combined, into: rest, at: 0, count: leftover,
                 sourceOffset: Self.framesPerPacket)
            pending = rest
        } else {
            pending = nil
        }
        return frame
    }

    /// Copy `count` frames between buffers of the same format.
    ///
    /// Handles both interleaved and deinterleaved layouts: ScreenCaptureKit
    /// hands over deinterleaved float, where each channel lives in its own
    /// buffer, so copying only channel 0 would silently drop the right channel.
    private func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer,
                      at destinationOffset: AVAudioFrameCount, count: AVAudioFrameCount,
                      sourceOffset: AVAudioFrameCount = 0) {
        guard let src = source.floatChannelData, let dst = destination.floatChannelData else { return }
        let channels = Int(source.format.channelCount)
        let stride = source.stride            // 1 when deinterleaved
        for channel in 0..<channels {
            let from = src[channel].advanced(by: Int(sourceOffset) * stride)
            let to = dst[channel].advanced(by: Int(destinationOffset) * stride)
            to.update(from: from, count: Int(count) * stride)
        }
    }

    /// One encoded packet, or nil when this buffer produced no output.
    struct Encoded {
        let data: Data
        let hasConfig: Bool
    }

    /// Encode one PCM buffer.
    ///
    /// AAC is framed in 1024-sample blocks, so a PCM buffer that does not fill
    /// one yields nothing and the converter keeps the remainder — returning nil
    /// here is ordinary, not an error.
    func encode(_ pcm: AVAudioPCMBuffer) -> Encoded? {
        guard let converter, let outputFormat else { return nil }

        let out = AVAudioCompressedBuffer(
            format: outputFormat,
            packetCapacity: 1,
            maximumPacketSize: converter.maximumOutputPacketSize)

        // Accumulate until a full AAC frame's worth of samples is available.
        //
        // ScreenCaptureKit delivers audio in whatever chunk size it likes, and
        // AAC-LC is framed in fixed 1024-sample blocks. Handing the converter a
        // short chunk makes it emit a stub packet a few bytes long instead of
        // nothing, and those went out as undecodable 6-byte payloads. Feeding
        // it only whole frames is what makes the output real AAC.
        // Normalise first: `append` copies via floatChannelData, which is nil
        // for the interleaved Int16 ReplayKit delivers.
        guard let normalised = normalise(pcm), let staged = append(normalised) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            // Hand the converter this buffer exactly once. Returning it again
            // would re-encode the same audio; reporting .noDataNow instead lets
            // the converter emit what it has and ask again next call.
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return staged
        }

        switch status {
        case .haveData:
            break
        case .inputRanDry, .endOfStream:
            return nil          // not enough samples for a full AAC frame yet
        case .error:
            if let conversionError { Log.info("audio encode error: \(conversionError)") }
            return nil
        @unknown default:
            return nil
        }

        // A real AAC-LC frame at 128 kbps is a few hundred bytes. Anything tiny
        // is the converter emitting a stub because it did not have a full 1024
        // samples to work with — sending those produced a stream of 6-byte
        // payloads that failed to decode on every single packet. Drop them
        // rather than putting undecodable audio on the wire.
        guard out.byteLength >= 16 else { return nil }
        let data = Data(bytes: out.data, count: Int(out.byteLength))

        // Flag the config on the first packet after a (re)configuration so a
        // receiver knows the cookie it holds applies to what follows.
        let hasConfig = needsConfigFlag
        needsConfigFlag = false
        return Encoded(data: data, hasConfig: hasConfig)
    }

    func reset() {
        converter?.reset()
        pending = nil   // stale samples would click on reconnect
        inputConverter = nil
        inputConverterSource = nil
        needsConfigFlag = true
    }
}
