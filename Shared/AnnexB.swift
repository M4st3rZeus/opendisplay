// Compiled into the Mac sender and the iOS broadcast extension (see
// project.yml `sources`). Both encode video and put Annex B on the same wire,
// so the conversion lives here rather than once per sender.

import Foundation
import CoreMedia
import VideoToolbox

/// Elementary-stream conversion for the video senders.
///
/// VideoToolbox hands back AVCC: each NALU prefixed with its 4-byte length.
/// The wire carries Annex B: each NALU prefixed with a start code, with the
/// parameter sets repeated on every keyframe so a receiver that joins late,
/// or resyncs after a drop, can start decoding without a side channel.
enum AnnexB {

    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Whether this sample is a sync frame.
    ///
    /// Absent attachments mean "not marked as a non-sync frame", which is the
    /// keyframe case — hence the `true` default rather than `false`.
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    /// Convert one encoded sample to Annex B, prepending the parameter
    /// sets when it is a keyframe. Handles both HEVC (VPS/SPS/PPS) and
    /// H.264 (SPS/PPS); the codec is read from the sample itself, so a
    /// caller does not have to know which it configured.
    static func convert(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend parameter sets (VPS/SPS/PPS for HEVC, SPS/PPS for H.264).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            let codec = CMFormatDescriptionGetMediaSubType(fmt)
            if codec == kCMVideoCodecType_HEVC {
                var count = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmt, parameterSetIndex: 0,
                    parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr {
                    for i in 0..<count {
                        var psPtr: UnsafePointer<UInt8>?
                        var psLen = 0
                        if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                            fmt, parameterSetIndex: i,
                            parameterSetPointerOut: &psPtr, parameterSetSizeOut: &psLen,
                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                           let psPtr {
                            out.append(contentsOf: startCode)
                            out.append(Data(bytes: psPtr, count: psLen))
                        }
                    }
                }
            } else {
                for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                    var psPtr: UnsafePointer<UInt8>?
                    var psLen = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            fmt, parameterSetIndex: i,
                            parameterSetPointerOut: &psPtr,
                            parameterSetSizeOut: &psLen,
                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                       let psPtr {
                        out.append(contentsOf: startCode)
                        out.append(Data(bytes: psPtr, count: psLen))
                    }
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }
}
