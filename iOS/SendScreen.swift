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
    /// The chosen receiver, or nil when nothing is selectable.
    ///
    /// Seeded from the persisted name so a returning user keeps their choice,
    /// but only counts as chosen while that device is actually discoverable —
    /// otherwise the row offered "Start mirroring" to a device from a previous
    /// session that is not on the network, and the broadcast died on start.
    @State private var target = BroadcastTarget.serviceName
    private let picker = BroadcastPickerButton()

    /// Whether the current target is present in the discovered list.
    private var targetIsAvailable: Bool {
        guard let target else { return false }
        return browser.names.contains(target)
    }

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
                    // The picker view is a 44pt record glyph and only it
                    // receives taps, so a row built around it reads as a label
                    // and nothing invites the tap. Overlaying it across the
                    // whole row keeps the system control (there is no API to
                    // start a broadcast programmatically) while making the
                    // entire row the target, with a chevron to say so.
                    HStack(spacing: 12) {
                        Image(systemName: "record.circle")
                            .foregroundStyle(targetIsAvailable ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(targetIsAvailable
                                 ? "Start mirroring to “\(target!)”"
                                 : "Choose a device above first")
                                .foregroundStyle(targetIsAvailable ? .primary : .secondary)
                            if targetIsAvailable {
                                Text("Tap to start")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if targetIsAvailable {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { picker.present() }
                    // Zero-sized and hidden: it exists to own the system
                    // control, while the row above is what the user taps.
                    .background(picker.frame(width: 0, height: 0).hidden())
                    .disabled(!targetIsAvailable)
                } footer: {
                    Text("Your entire screen is mirrored — everything you see, in every app — until you stop it from the red indicator in the status bar. Mirroring is view-only: touches on the other device are not sent back.")
                }
            }
            .onChange(of: browser.names) { names in
                // A remembered device that is no longer discoverable must not
                // stay selected: the extension would dial a stale address and
                // the broadcast would die on start. Cleared here rather than
                // only greyed out, so what is persisted matches what is shown.
                if let target, !names.contains(target) {
                    BroadcastTarget.serviceName = nil
                    BroadcastTarget.address = nil
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
/// Hosts RPSystemBroadcastPickerView and exposes a way to trigger it.
///
/// Only the picker's own 44pt glyph receives taps, so a row built around it
/// reads as a label and nothing invites the tap. There is no API to start a
/// broadcast programmatically — the system sheet is mandatory — so the row
/// forwards its tap to the picker's internal button instead.
private struct BroadcastPickerButton: UIViewRepresentable {
    /// Held outside the view tree so `present()` can reach the live instance.
    private let host = RPSystemBroadcastPickerView(
        frame: CGRect(x: 0, y: 0, width: 44, height: 44))

    init() {
        host.preferredExtension = BroadcastTarget.extensionBundleID
        host.showsMicrophoneButton = false
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView { host }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}

    /// Tap the picker on the user's behalf.
    ///
    /// UIKit offers no public "show the sheet" call, so this sends a touch to
    /// the UIButton the picker builds internally. If Apple ever changes that
    /// hierarchy the button is simply not found and nothing happens, which is
    /// why the picker also stays in the view tree rather than being replaced.
    func present() {
        guard let button = host.subviews.compactMap({ $0 as? UIButton }).first else { return }
        button.sendActions(for: .touchUpInside)
    }
}
