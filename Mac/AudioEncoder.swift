import AVFoundation
import Foundation

/// PCM → AAC-LC for the audio channel, kept out of MacSender so the sender
/// stays about streaming and this stays about codecs.
///
/// ScreenCaptureKit hands us system audio as PCM; this converts it to AAC-LC
/// at a fixed bitrate. Audio is ~1% of video's bandwidth, so there is nothing
/// to gain from adapting it to the quality setting the way the video encoder
/// does — a fixed rate is one less thing to get wrong.
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

    /// Build (or rebuild) the converter for `format`. Returns false if the
    /// format cannot be encoded, in which case the caller drops audio rather
    /// than sending something no receiver can read.
    @discardableResult
    func prepare(for format: AVAudioFormat) -> Bool {
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
        self.needsConfigFlag = true
        Log.info("audio: encoding \(Int(format.sampleRate))Hz \(format.channelCount)ch AAC-LC @ \(Self.bitRate / 1000)kbps")
        return true
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
            return pcm
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

        guard out.byteLength > 0 else { return nil }
        let data = Data(bytes: out.data, count: Int(out.byteLength))

        // Flag the config on the first packet after a (re)configuration so a
        // receiver knows the cookie it holds applies to what follows.
        let hasConfig = needsConfigFlag
        needsConfigFlag = false
        return Encoded(data: data, hasConfig: hasConfig)
    }

    func reset() {
        converter?.reset()
        needsConfigFlag = true
    }
}
