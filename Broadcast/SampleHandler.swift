// The broadcast upload extension's entry point (issue #123). iOS runs this in
// its own ~50MB process while the red recording indicator is up; ReplayKit
// delivers the whole screen here regardless of which app is frontmost — the
// only sanctioned way to capture beyond your own app on iOS.

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

    private var sender: BroadcastSender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let target = BroadcastTarget.serviceName, !target.isEmpty else {
            // No target chosen (broadcast started straight from Control
            // Center before ever opening the app's send screen).
            finish("Open OpenDisplay and choose a device to send to first.")
            return
        }
        Log.info("broadcast started -> \(target)")
        let sender = BroadcastSender(targetService: target,
                                     targetAddress: BroadcastTarget.address)
        sender.onFatal = { [weak self] message in self?.finish(message) }
        self.sender = sender
        sender.start()
    }

    override func broadcastPaused() {
        Log.info("broadcast paused")
        sender?.setPaused(true)
    }

    override func broadcastResumed() {
        Log.info("broadcast resumed")
        sender?.setPaused(false)
    }

    override func broadcastFinished() {
        Log.info("broadcast finished")
        sender?.stop()
        sender = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            sender?.process(sampleBuffer)
        case .audioApp:
            // What the apps on screen are playing — the counterpart of the
            // Mac sender's system audio.
            sender?.processAudio(sampleBuffer)
        case .audioMic:
            // Deliberately dropped: the microphone is the room, not the
            // screen, and forwarding it would be recording the user.
            break
        @unknown default:
            break
        }
    }

    /// End the broadcast with a message the system surfaces in its alert —
    /// the only user-visible channel an upload extension has.
    private func finish(_ message: String) {
        Log.info("finishing broadcast: \(message)")
        finishBroadcastWithError(NSError(
            domain: "OpenDisplay", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
