import XCTest
import CoreMedia


final class AnnexBTests: XCTestCase {

    func testStartCodeIsFourByteAnnexB() {
        XCTAssertEqual(AnnexB.startCode, [0, 0, 0, 1])
    }

    /// A sample with no attachment array is a keyframe. The attachment marks
    /// the *non*-sync case, so defaulting to false here would make every such
    /// frame skip its parameter sets and leave a late receiver unable to
    /// start decoding.
    func testSampleWithoutAttachmentsCountsAsKeyframe() throws {
        var format: CMFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 64, height: 64,
            extensions: nil,
            formatDescriptionOut: &format), noErr)
        let fmt = try XCTUnwrap(format)

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sample), noErr)

        XCTAssertTrue(AnnexB.isKeyframe(try XCTUnwrap(sample)))
    }
}
