import Foundation
import Network

/// TCP connection to the Blender add-on. Frames: u32 headerLen | u32 payloadLen | JSON | bytes (big-endian).
final class BlenderClient {
    enum State: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    var onState: ((State) -> Void)?
    /// (message type, raw JSON header, payload) — called on the network queue
    var onMessage: ((String, Data, Data) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "blendpaint.net", qos: .userInitiated)
    private let lock = NSLock()
    private var _pending = 0
    private var generation = 0

    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _pending
    }

    func connect(host: String, port: UInt16) {
        disconnect()
        generation += 1
        let gen = generation
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.connectionTimeout = 5
        }
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        connection = c
        lock.lock(); _pending = 0; lock.unlock()
        emit(.connecting(host))
        c.stateUpdateHandler = { [weak self] st in
            guard let self, gen == self.generation else { return }
            switch st {
            case .ready:
                self.emit(.connected(host))
                self.receiveFrame(c, gen: gen)
            case .failed(let e):
                self.emit(.failed(e.localizedDescription))
                c.cancel()
            case .waiting(let e):
                self.emit(.failed(e.localizedDescription))
                c.cancel()
            case .cancelled:
                self.emit(.disconnected)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    func disconnect() {
        generation += 1
        connection?.cancel()
        connection = nil
    }

    private func emit(_ s: State) {
        DispatchQueue.main.async { self.onState?(s) }
    }

    func send(_ header: [String: Any], payload: Data = Data()) {
        guard let c = connection,
              let hb = try? JSONSerialization.data(withJSONObject: header) else { return }
        var frame = Data(capacity: 8 + hb.count)
        var hl = UInt32(hb.count).bigEndian
        var pl = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &hl) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &pl) { frame.append(contentsOf: $0) }
        frame.append(hb)
        let total = payload.count
        lock.lock(); _pending += total; lock.unlock()
        c.send(content: frame, completion: .contentProcessed { _ in })
        if total > 0 {
            c.send(content: payload, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self._pending -= total; self.lock.unlock()
            })
        }
    }

    private func receiveExactly(_ c: NWConnection, _ n: Int, _ done: @escaping (Data?) -> Void) {
        if n == 0 { done(Data()); return }
        c.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
            if let data, data.count == n {
                done(data)
            } else if error != nil || isComplete {
                done(nil)
            } else if let data {
                // partial (should not happen with min == max) – read the rest
                self.receiveExactly(c, n - data.count) { rest in
                    guard let rest else { done(nil); return }
                    done(data + rest)
                }
            } else {
                done(nil)
            }
        }
    }

    private func receiveFrame(_ c: NWConnection, gen: Int) {
        receiveExactly(c, 8) { [weak self] head in
            guard let self, gen == self.generation else { return }
            guard let head else { c.cancel(); return }
            let bytes = [UInt8](head)
            let hl = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            let pl = Int(UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7]))
            self.receiveExactly(c, hl) { hdr in
                guard let hdr else { c.cancel(); return }
                self.receiveExactly(c, pl) { payload in
                    guard let payload else { c.cancel(); return }
                    if let t = try? JSONDecoder().decode(MessageType.self, from: hdr) {
                        self.onMessage?(t.type, hdr, payload)
                    }
                    self.receiveFrame(c, gen: gen)
                }
            }
        }
    }
}

// MARK: - LAN scan (no Bonjour/multicast entitlement needed, works with sideloaded builds)

struct DiscoveredHost: Identifiable, Hashable {
    var id: String { ip }
    let ip: String
}

enum HostScanner {
    static func localIPv4() -> [(ip: String, mask: String)] {
        var result: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    if let m = ifa.ifa_netmask {
                        getnameinfo(m, socklen_t(m.pointee.sa_len), &mask, socklen_t(mask.count), nil, 0, NI_NUMERICHOST)
                    }
                    result.append((String(cString: host), String(cString: mask)))
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }

    /// Tries TCP connects to every host of the local /24 on `port`.
    static func scan(port: UInt16, timeout: TimeInterval = 1.2, found: @escaping (String) -> Void, finished: @escaping () -> Void) {
        let ips = localIPv4()
        guard let me = ips.first?.ip else { DispatchQueue.main.async(execute: finished); return }
        let parts = me.split(separator: ".")
        guard parts.count == 4 else { DispatchQueue.main.async(execute: finished); return }
        let prefix = parts[0...2].joined(separator: ".")
        let q = DispatchQueue(label: "blendpaint.scan", attributes: .concurrent)
        let group = DispatchGroup()
        let sem = DispatchSemaphore(value: 48)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        DispatchQueue.global().async {
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                sem.wait()
                group.enter()
                let c = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: .tcp)
                var done = false
                let lock = NSLock()
                func finish(_ ok: Bool) {
                    lock.lock()
                    if done { lock.unlock(); return }
                    done = true
                    lock.unlock()
                    c.cancel()
                    if ok { DispatchQueue.main.async { found(ip) } }
                    sem.signal()
                    group.leave()
                }
                c.stateUpdateHandler = { st in
                    switch st {
                    case .ready: finish(true)
                    case .failed, .waiting, .cancelled: finish(false)
                    default: break
                    }
                }
                c.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
            group.notify(queue: .main, execute: finished)
        }
    }
}
