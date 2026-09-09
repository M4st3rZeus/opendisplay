// Send this device's screen to another iPad/iPhone (issue #123). The app only
// picks the target and hands it to the broadcast extension via app-group
// defaults — the actual capture/encode/stream pipeline lives in the extension
// (Broadcast/BroadcastSender.swift), because system-wide capture on iOS only
// exists there.

import SwiftUI
import Network
import ReplayKit

/// Discovers other OpenDisplay receivers over Bonjour. Excludes this device
/// by its own advertised service name — the browser sees our own listener
/// too, and streaming to yourself is a hall of mirrors. (TXT records with the
/// install id would be more precise, but NWBrowser often omits them — the
/// same reason the Mac's WiFi picker matches by name.)
final class ReceiverBrowser: ObservableObject {
    @Published var names: [String] = []
    /// Address per name, for receivers the unicast sweep found. Bonjour
    /// results have no entry — they resolve by service name as before.
    @Published var addresses: [String: String] = [:]
    private var browser: NWBrowser?
    private var ownName = ""
    private var sweepTimer: Timer?
    private var bonjourNames: [String] = []

    func start(excluding own: String) {
        ownName = own
        stop()
        let params = NWParameters()
        // Match the sender's dial parameters: with peer-to-peer on both, two
        // iPads with no shared WiFi can still find each other over AWDL.
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_opensidecar._tcp", domain: nil),
                                using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let names = results.compactMap { result -> String? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self.ownName else { return nil }
                return name
            }
            DispatchQueue.main.async {
                self.bonjourNames = names
                self.merge()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
        startSweeps()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
    }

    /// Sweep alongside Bonjour, for networks whose access point drops
    /// multicast between clients — there NWBrowser returns nothing and this
    /// is the only way to see the receiver (see UnicastDiscovery).
    private func startSweeps() {
        sweepTimer?.invalidate()
        sweep()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.sweep()
        }
    }

    private func sweep() {
        UnicastDiscovery.sweep(queue: .global(qos: .utility)) { [weak self] found in
            DispatchQueue.main.async {
                guard let self else { return }
                for f in found where f.name != self.ownName {
                    self.addresses[f.name] = f.host
                }
                self.merge()
            }
        }
    }

    private func merge() {
        let all = Set(bonjourNames).union(addresses.keys).subtracting([ownName])
        names = all.sorted()
    }
}

struct SendScreen: View {
    @ObservedObject var receiver: StreamReceiver
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = ReceiverBrowser()
    @State private var target = BroadcastTarget.serviceName

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.names.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for OpenDisplay devices…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(browser.names, id: \.self) { name in
                        Button {
                            target = name
                            BroadcastTarget.serviceName = name
                            // Record the address for sweep-discovered
                            // receivers, and clear it for Bonjour ones so a
                            // stale lease is never dialled.
                            BroadcastTarget.address = browser.addresses[name]
                        } label: {
                            HStack {
                                Label(name, systemImage: "ipad.landscape")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if name == target {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Send to")
                } footer: {
                    Text("Open OpenDisplay on the other iPad or iPhone — it appears here when both devices are on the same WiFi or near each other.")
                }

                Section {
                    HStack(spacing: 12) {
                        BroadcastPickerButton()
                            .frame(width: 44, height: 44)
                        Text(target == nil ? "Choose a device above first"
                                           : "Start mirroring to “\(target!)”")
                            .foregroundStyle(target == nil ? .secondary : .primary)
                    }
                    // The label greyed out without a target but the picker
                    // still opened the system sheet, and a broadcast started
                    // with no target set dies immediately in
                    // broadcastStarted — disable the control itself, not just
                    // its caption.
                    .disabled(target == nil)
                } footer: {
                    Text("Your entire screen is mirrored — everything you see, in every app — until you stop it from the red indicator in the status bar. Mirroring is view-only: touches on the other device are not sent back.")
                }
            }
            .navigationTitle("Send Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { browser.start(excluding: receiver.serviceName) }
            .onDisappear { browser.stop() }
        }
    }
}

/// The system's broadcast start/stop button. There is no API to start a
/// broadcast programmatically — this picker (or Control Center) is the only
/// entry point, so the row hosts the real control rather than imitating one.
private struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        // Pin the sheet to our extension so unrelated broadcast services
        // (other screen-recording apps) aren't offered.
        picker.preferredExtension = BroadcastTarget.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
