import Foundation
import Network

/// Finds receivers by asking each known host directly, for networks where
/// Bonjour cannot work.
///
/// mDNS discovery is multicast (UDP 5353 to 224.0.0.251), and some access
/// points forward unicast between clients while dropping multicast across
/// them. Measured on one such network: the Mac was joined to the mDNS group
/// and saw other Macs, but no service from the iPhone ever arrived — not
/// OpenDisplay's, not Apple's own `_companion-link`. The phone was
/// advertising correctly the whole time; a unicast mDNS query straight to its
/// address returned the service and its hostname immediately.
///
/// So this asks the same question over unicast. Each candidate host gets one
/// mDNS PTR query for `_opensidecar._tcp.local` on port 5353; whoever answers
/// is running a receiver. NWBrowser keeps running alongside — on a normal
/// network it is faster and this finds nothing new.
///
/// Candidates are the ARP neighbours plus the local IPv4 subnet, capped at
/// 1024 addresses. The neighbour cache alone is not enough: entries age out,
/// and an idle receiver is precisely the host that has aged out — measured,
/// the phone was missing from `arp -an` while answering a unicast query
/// instantly. One 12-byte datagram per address to port 5353, so a /22 sweep
/// is ~12 KB and touches only the mDNS port, not a port scan.
enum UnicastDiscovery {

    struct Found: Hashable {
        let name: String        // Bonjour instance name, as advertised
        let host: String        // the address that answered
    }

    /// One sweep. Calls back on `queue` with everything that answered.
    ///
    /// `deadline` bounds the whole sweep, not each host: they are queried in
    /// parallel, so a few unreachable neighbours cost nothing.
    static func sweep(queue: DispatchQueue,
                      deadline: TimeInterval = 4.0,
                      completion: @escaping ([Found]) -> Void) {
        // Everything below runs on `queue`. Enumerating the subnet and
        // opening sockets must never touch the caller's thread: the first
        // version did both inline and, called from the main actor, froze the
        // UI hard enough that the app would not launch.
        queue.async {
            let hosts = candidateAddresses()
            guard !hosts.isEmpty else {
                completion([])
                return
            }

            let state = SweepState()
            // Batched rather than all at once: a whole subnet of sockets
            // exhausts the process's file descriptors. Batches are dispatched
            // recursively, so nothing ever blocks a thread waiting for a slot.
            let batchSize = 64
            var index = 0

            func sendBatch() {
                guard index < hosts.count, !state.finished else { return }
                let upper = min(index + batchSize, hosts.count)
                for host in hosts[index..<upper] {
                    let conn = NWConnection(
                        to: .hostPort(host: NWEndpoint.Host(host), port: 5353),
                        using: .udp)
                    state.track(conn)
                    conn.stateUpdateHandler = { s in
                        switch s {
                        case .ready:
                            conn.send(content: ptrQuery,
                                      completion: .contentProcessed { _ in })
                            conn.receiveMessage { data, _, _, _ in
                                if let data, let name = instanceName(in: data) {
                                    state.add(Found(name: name, host: host))
                                }
                                conn.cancel()
                            }
                        case .failed, .cancelled:
                            conn.cancel()
                        default:
                            break
                        }
                    }
                    conn.start(queue: queue)
                }
                index = upper
                if index < hosts.count {
                    queue.asyncAfter(deadline: .now() + 0.15) { sendBatch() }
                }
            }
            sendBatch()

            // One deadline for the sweep as a whole. Hosts that never answer
            // are the common case, so there is nothing to wait on per host.
            queue.asyncAfter(deadline: .now() + deadline) {
                completion(state.finish())
            }
        }
    }

    /// Sweep bookkeeping, guarded because replies land on the sweep queue
    /// while the deadline fires on it too.
    private final class SweepState {
        private let lock = NSLock()
        private var found: [Found] = []
        private var connections: [NWConnection] = []
        private var done = false

        var finished: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }

        func track(_ conn: NWConnection) {
            lock.lock(); connections.append(conn); lock.unlock()
        }

        func add(_ result: Found) {
            lock.lock()
            if !found.contains(result) { found.append(result) }
            lock.unlock()
        }

        func finish() -> [Found] {
            lock.lock()
            done = true
            let result = found
            let open = connections
            connections = []
            lock.unlock()
            open.forEach { $0.cancel() }
            return result
        }
    }

    // MARK: - Wire format

    /// A standard DNS query for `_opensidecar._tcp.local` PTR.
    ///
    /// mDNS uses the DNS wire format, so this is an ordinary query sent to
    /// port 5353 rather than 53. ID 0 and no flags: responders answer a
    /// unicast query from an ephemeral port directly.
    private static let ptrQuery: Data = {
        var q = Data([0x00, 0x00,             // id
                      0x00, 0x00,             // flags: standard query
                      0x00, 0x01,             // one question
                      0x00, 0x00,             // no answers
                      0x00, 0x00,             // no authority
                      0x00, 0x00])            // no additional
        for label in ["_opensidecar", "_tcp", "local"] {
            q.append(UInt8(label.utf8.count))
            q.append(contentsOf: Array(label.utf8))
        }
        q.append(0x00)                        // root label
        q.append(contentsOf: [0x00, 0x0C])    // QTYPE PTR
        q.append(contentsOf: [0x00, 0x01])    // QCLASS IN
        return q
    }()

    /// Pull the service instance name out of a PTR response.
    ///
    /// Only the first answer's RDATA is read, and only its first label — that
    /// is the instance name (`My iPhone._opensidecar._tcp.local`). Compression
    /// pointers are skipped rather than followed: the name we want is always
    /// stored inline as the first label, so following them buys nothing and
    /// costs a loop that would need its own cycle guard.
    static func instanceName(in response: Data) -> String? {
        let bytes = [UInt8](response)
        guard bytes.count > 12 else { return nil }
        // Answer count must be non-zero, or nothing is advertising.
        guard (Int(bytes[6]) << 8 | Int(bytes[7])) > 0 else { return nil }

        /// Step over one DNS name, whether it ends in a root label or a
        /// compression pointer.
        ///
        /// The distinction is the whole bug this had: a pointer *is* the end
        /// of the name and consumes exactly two bytes, while a root label
        /// consumes one. Advancing past both — as a shared `if bytes[i] == 0`
        /// after the loop did — ate a byte of the following record whenever
        /// the name was a pointer, which is the normal case for an answer.
        /// Every subsequent field then read one byte late: rdlength came back
        /// as 77 instead of 28 and the name never parsed.
        func skipName(from start: Int) -> Int? {
            var i = start
            while i < bytes.count {
                let byte = bytes[i]
                if byte & 0xC0 == 0xC0 {
                    return i + 2 <= bytes.count ? i + 2 : nil
                }
                if byte == 0 { return i + 1 }
                i += Int(byte) + 1
            }
            return nil
        }

        // Question: name, then QTYPE and QCLASS.
        guard var i = skipName(from: 12) else { return nil }
        i += 4
        // Answer: name, type(2), class(2), ttl(4), rdlength(2), then RDATA.
        guard let afterName = skipName(from: i) else { return nil }
        i = afterName + 8
        guard i + 2 <= bytes.count else { return nil }
        i += 2                                  // rdlength
        guard i < bytes.count else { return nil }

        let length = Int(bytes[i])
        guard length > 0, i + 1 + length <= bytes.count else { return nil }
        return String(bytes: bytes[(i + 1)..<(i + 1 + length)], encoding: .utf8)
    }

    // MARK: - Candidates

    /// Hosts to ask: the ARP neighbours plus every address in the local IPv4
    /// subnet.
    ///
    /// The ARP cache alone is not enough. Entries age out when nothing has
    /// talked to a host recently, and the receiver we are looking for is
    /// exactly such a host — measured: the phone was absent from `arp -an`,
    /// answered a unicast mDNS query immediately, and *then* appeared in the
    /// cache because that query populated it. Discovery that only asks known
    /// neighbours therefore cannot find an idle receiver.
    ///
    /// So the subnet is enumerated as well, capped at `maxSubnetHosts` — a /22
    /// is 1024 addresses, and anything wider is a network where this approach
    /// is the wrong tool anyway.
    static func candidateAddresses() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for addr in neighbourAddresses() + subnetAddresses() {
            guard seen.insert(addr).inserted else { continue }
            result.append(addr)
        }
        return result
    }

    /// Ceiling on a subnet sweep. One 12-byte datagram each, so a /22 is
    /// ~12 KB of traffic; a /16 would be 786 KB and pointless.
    private static let maxSubnetHosts = 1024

    /// Every usable host address in the primary IPv4 interface's subnet.
    private static func subnetAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            // Same exclusions as the receiver's address advertisement: these
            // interfaces never carry the stream.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("pdp_ip") || name.hasPrefix("anpi") { continue }

            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let hostCount = ~netmask
            guard hostCount > 1, hostCount <= UInt32(maxSubnetHosts) else { continue }

            let network = addr & netmask
            // Skip the network and broadcast addresses at either end.
            for offset in 1..<hostCount {
                let candidate = network | offset
                guard candidate != addr else { continue }   // ourselves
                result.append(String(format: "%d.%d.%d.%d",
                                     (candidate >> 24) & 0xFF, (candidate >> 16) & 0xFF,
                                     (candidate >> 8) & 0xFF, candidate & 0xFF))
            }
            break   // primary interface only
        }
        return result
    }

    /// Neighbours are not enumerated separately: `subnetAddresses()` already
    /// covers every host in the local subnet, which is a superset of the ARP
    /// cache. Shelling out to arp(8) also does not work on iOS, and this file
    /// is shared with the broadcast extension.
    private static func neighbourAddresses() -> [String] { [] }

}
