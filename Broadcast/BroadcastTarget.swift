// Compiled into BOTH the iOS app and the broadcast extension (see project.yml
// `sources`). App-group defaults are the only channel the two processes share:
// the app writes the chosen receiver here, the extension reads it when the
// system starts the broadcast (issue #123).

import Foundation

enum BroadcastTarget {
    /// The app's own bundle id, with the extension's `.broadcast` suffix
    /// stripped so both processes derive the same base.
    ///
    /// Derived rather than hardcoded because a fork or a personal-team build
    /// must rebrand every identifier to something its own team can register,
    /// and a literal here would silently keep pointing at the upstream ids —
    /// the picker would then find no extension and "Send this screen" would
    /// do nothing.
    private static let appBundleID: String = {
        let id = Bundle.main.bundleIdentifier ?? "com.peetzweg.opensidecar.ios"
        return id.hasSuffix(".broadcast") ? String(id.dropLast(".broadcast".count)) : id
    }()

    /// Must match `com.apple.security.application-groups` in both the app's
    /// and the extension's entitlements.
    static let appGroupID = "group.\(appBundleID)"

    /// The extension's bundle id — the app's broadcast picker pins itself to
    /// it so the system sheet doesn't list unrelated broadcast services.
    static let extensionBundleID = "\(appBundleID).broadcast"

    private static let serviceKey = "broadcastTargetService"

    /// Bonjour service name of the receiver to stream to. Nil until the user
    /// picks a device in the app.
    static var serviceName: String? {
        get { UserDefaults(suiteName: appGroupID)?.string(forKey: serviceKey) }
        set { UserDefaults(suiteName: appGroupID)?.set(newValue, forKey: serviceKey) }
    }
}
