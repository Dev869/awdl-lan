import Foundation
import Network

// awdl-lan-helper — owns the radio so the JVM doesn't have to.
//
// host mode:   advertise _awdllan._tcp over AWDL, relay each peer to 127.0.0.1:<port>
// browse mode: find peers, and on `connect` expose one as a loopback port
//
// Speaks newline-delimited JSON on stdin/stdout. Closing stdin kills it, so it
// can never outlive Minecraft.

let serviceType = "_awdllan._tcp"
let q = DispatchQueue(label: "awdllan")

// MARK: - Output

func emit(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

/// Diagnostics go to stderr so they never corrupt the JSON stream on stdout.
func trace(_ message: String) {
    FileHandle.standardError.write("[trace] \(message)\n".data(using: .utf8)!)
}

/// Network.framework does not retain listeners or browsers for you. Anything
/// started must be held here or it dies when its creating function returns.
var liveListeners: [NWListener] = []
var liveBrowsers: [NWBrowser] = []
var liveConnections: [NWConnection] = []

func watch(_ connection: NWConnection, _ label: String) {
    liveConnections.append(connection)
    connection.stateUpdateHandler = { state in
        trace("\(label): \(state)")
        if case .failed(let e) = state { trace("\(label) failed: \(e)") }
    }
}

/// Local Network denial is the failure this project most needs to name out loud:
/// macOS 15+ can refuse a CLI binary with no prompt, and the grant can't be
/// reset with tccutil. Never let it surface as an empty server list.
func emitError(_ error: NWError) {
    var code = "network_error"
    switch error {
    case .dns(let c) where c == -65570: code = "local_network_denied"  // kDNSServiceErr_PolicyDenied
    case .posix(.EPERM): code = "local_network_denied"
    default: break
    }
    emit(["event": "error", "code": code, "message": "\(error)"])
}

// MARK: - Relay

/// How long a half-closed pair may linger before both sides are cancelled.
let halfCloseTimeout: TimeInterval = 30

/// Pump bytes both ways, closing each direction independently.
///
/// A half-close must NOT tear down the pair: the peer connection may still be
/// dialling when the local side finishes writing, and cancelling it there
/// discards everything queued for delivery. Propagate the FIN, and only fully
/// close once both directions have drained.
// ponytail: fire-and-forget sends, no backpressure. Fine for one peer on a fast
// radio; add a credit window if AWDL throughput testing shows buffer growth.
func relay(_ a: NWConnection, _ b: NWConnection) {
    var closedDirections = 0   // all callbacks land on the serial queue `q`

    func pump(_ from: NWConnection, _ to: NWConnection, _ label: String) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }

            if let error {
                trace("relay \(label) error: \(error)")
                a.cancel()
                b.cancel()
                return
            }

            if isComplete {
                trace("relay \(label) half-closed")
                to.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
                closedDirections += 1
                if closedDirections == 2 {
                    a.cancel()
                    b.cancel()
                    return
                }
                // Reap a pair that stays half-closed. A peer can go away without its
                // FIN ever arriving, and then neither side is ever cancelled: the
                // sockets linger and the tunnel is still reported as carrying a
                // session. A Minecraft client that has stopped sending is one that
                // has disconnected, so there is nothing here worth waiting on.
                q.asyncAfter(deadline: .now() + halfCloseTimeout) {
                    guard closedDirections < 2 else { return }
                    trace("relay \(label): other direction never closed, reaping")
                    a.cancel()
                    b.cancel()
                }
                return
            }

            pump(from, to, label)
        }
    }

    pump(a, b, "a->b")
    pump(b, a, "b->a")
}

func p2pParameters() -> NWParameters {
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    return params
}

// MARK: - Host

func runHost(port: UInt16, name: String, code: String) {
    let listener: NWListener
    do {
        listener = try NWListener(using: p2pParameters())
    } catch {
        emit(["event": "error", "code": "listener_failed", "message": "\(error)"])
        exit(1)
    }

    var txt = NWTXTRecord()
    txt["code"] = code
    txt["world"] = name
    listener.service = NWListener.Service(name: bonjourSafe(name), type: serviceType, txtRecord: txt)

    listener.newConnectionHandler = { peer in
        trace("host: inbound peer")
        let local = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        watch(peer, "host.peer")
        watch(local, "host.local")
        peer.start(queue: q)
        local.start(queue: q)
        relay(peer, local)
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: emit(["event": "ready", "mode": "host", "port": Int(port)])
        case .failed(let e): emitError(e); exit(1)
        default: break
        }
    }

    liveListeners.append(listener)
    listener.start(queue: q)
}

/// Bonjour service names cap at 63 bytes and choke on dots. World names don't care.
func bonjourSafe(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(of: ".", with: " ")
    return String(cleaned.prefix(50))
}

// MARK: - Browse

/// A world can be advertised on more than one interface at once — joined to a Wi-Fi
/// network, the same host is reachable over both en0 and awdl0. Track sightings as a
/// set per world so a second sighting is not a second world, and one sighting going
/// away is not a loss.
var peers: [String: Set<NWEndpoint>] = [:]
var tunnels: [String: NWListener] = [:]

/// The radios each world has been seen on.
///
/// This exists because a browse result's endpoint is *not* interface-scoped: every
/// sighting of a world carries the same unscoped Bonjour name, and dialling it leaves
/// the choice of interface entirely to the stack. The result's interface list is the
/// only handle on the individual radios, and pinning a dial to one of them is the only
/// way to insist on a path the stack did not pick.
var peerPaths: [String: [NWInterface]] = [:]

/// Local clients currently attached per tunnel. Drives the `inuse`/`idle` events the
/// mod uses to know a session is running through a tunnel.
var tunnelClients: [String: Int] = [:]

func runBrowse(autoConnect: Bool, match: String?) {
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: p2pParameters())

    browser.browseResultsChangedHandler = { _, changes in
        for change in changes {
            switch change {
            case .added(let result):
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                let firstSighting = peers[name, default: []].isEmpty
                peers[name, default: []].insert(result.endpoint)
                peerPaths[name] = result.interfaces
                guard firstSighting else { continue }
                var found: [String: Any] = ["event": "found", "id": name, "name": name]
                if case .bonjour(let txt) = result.metadata {
                    if let code = txt["code"] { found["code"] = code }
                    if let world = txt["world"] { found["name"] = world }
                }
                emit(found)
                // --match keeps a test run from dialling a real world that happens
                // to be advertising nearby.
                if autoConnect, match == nil || name == match {
                    connect(id: name)
                }
            // A radio coming or going under a world that never left arrives here, not
            // as an add or a remove. Without this the pinned dials below aim at
            // whichever radios happened to be up when the world was first seen.
            case .changed(_, let result, _):
                guard case .service(let name, _, _, _) = result.endpoint,
                      peers[name] != nil else { continue }
                peerPaths[name] = result.interfaces

            case .removed(let result):
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                peers[name]?.remove(result.endpoint)
                // Still reachable on another interface: not a loss.
                guard peers[name]?.isEmpty ?? true else { continue }
                peers[name] = nil
                peerPaths[name] = nil
                tunnels.removeValue(forKey: name)?.cancel()
                emit(["event": "lost", "id": name])
            default:
                break
            }
        }
    }

    browser.stateUpdateHandler = { state in
        switch state {
        case .ready: emit(["event": "ready", "mode": "browse"])
        case .failed(let e): emitError(e); exit(1)
        default: break
        }
    }

    liveBrowsers.append(browser)
    browser.start(queue: q)
}

/// Open one connection to a discovered world on behalf of one attached local client.
///
/// On a deadline rather than on failure, because a path with nothing behind it does
/// not fail — it sits in `preparing` indefinitely, and Minecraft sits with it.
let dialTimeout: TimeInterval = 8

/// Every path worth trying for a world, best first. `nil` means "any": let the stack
/// choose the interface.
///
/// Unpinned first, because when the shared network works that is both the fastest
/// answer and the right one. It is not a fallback, though. The choice the stack makes
/// is made once: if the path it picks cannot carry the connection, the attempt sits in
/// `preparing` until the deadline and no other radio is ever tried, and an unpinned
/// retry only repeats the same choice. Two Macs joined to one Wi-Fi network that will
/// not pass traffic between them is exactly that case, and exactly the case AWDL is
/// here to rescue — so the retries name a radio instead of asking for one.
///
/// Peer-to-peer before the rest, because it is the path that does not depend on
/// anything but the two machines. Matched by name: AWDL reports itself as `.wifi`, the
/// same type as the Wi-Fi interface it needs to be distinguished from.
///
/// Capped, because a chain of dead paths must still finish inside vanilla's own 30s
/// connect timeout.
func dialCandidates(_ id: String) -> [NWInterface?] {
    let seen = peerPaths[id] ?? []
    let radio = seen.filter { $0.name.hasPrefix("awdl") }
    let rest = seen.filter { !$0.name.hasPrefix("awdl") }
    let ordered: [NWInterface?] = [nil] + (radio + rest).map { Optional($0) }
    return Array(ordered.prefix(3))
}

func dial(id: String, for client: NWConnection, candidates: [NWInterface?]) {
    guard let pinned = candidates.first else {
        trace("dial \(id): nothing left to try")
        client.cancel()
        return
    }
    let remaining = Array(candidates.dropFirst())
    let via = pinned?.name ?? "any interface"

    // Always the unscoped name: the interface is carried by the parameters, since a
    // browse result's endpoint has no interface to inherit.
    let params = p2pParameters()
    params.requiredInterface = pinned
    let peer = NWConnection(
        to: .service(name: id, type: serviceType, domain: "local", interface: nil), using: params)
    liveConnections.append(peer)
    var settled = false   // relaying or given up; all mutations land on `q`

    /// This attempt is over. Hand the client to the next path, or close it — a client
    /// left holding a socket that will never speak is the worst outcome here.
    func giveUp(_ why: String) {
        guard !settled else { return }
        settled = true
        trace("dial \(id) via \(via): \(why)")
        peer.cancel()
        dial(id: id, for: client, candidates: remaining)
    }

    peer.stateUpdateHandler = { state in
        trace("tunnel.peer via \(via) (\(remaining.count) paths left): \(state)")
        switch state {
        case .ready:
            // Pumping only once the peer is up keeps the client's bytes in its own
            // socket buffer until there is somewhere to put them, which is what makes
            // handing the client to a second attempt safe.
            guard !settled else { return }
            settled = true
            relay(client, peer)
        case .failed(let e):
            giveUp("failed: \(e)")
        default:
            break
        }
    }

    q.asyncAfter(deadline: .now() + dialTimeout) { giveUp("no answer in \(Int(dialTimeout))s") }
    peer.start(queue: q)
}

func connect(id: String) {
    guard peers[id] != nil else {
        emit(["event": "error", "code": "unknown_peer", "message": id])
        return
    }
    // Guard on the tunnel existing, not on it having a port yet. A second `connect`
    // arriving in the gap before the first listener reports ready would otherwise
    // bind a second mouth and leak the first, leaving the caller holding the port of
    // a tunnel nothing points at.
    if let open = tunnels[id] {
        if let p = open.port {
            emit(["event": "connected", "id": id, "localPort": Int(p.rawValue)])
        }
        return
    }

    // Loopback only — nothing outside this machine should reach the tunnel mouth.
    let localParams = NWParameters.tcp
    localParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

    guard let listener = try? NWListener(using: localParams) else {
        emit(["event": "error", "code": "listener_failed", "message": "loopback bind failed"])
        return
    }
    tunnels[id] = listener

    // One peer connection per local client, and the mouth stays open. A join that
    // fails or a player who leaves and comes back gets a fresh dial on the same port
    // instead of a listener that was cancelled after the first attempt.
    listener.newConnectionHandler = { client in
        let candidates = dialCandidates(id)
        trace("connect: local client attached, paths ["
              + candidates.map { $0?.name ?? "any" }.joined(separator: ", ") + "]")

        // Tell the mod this tunnel is carrying a session. It cannot work this out for
        // itself: joining is what closes the screen that keeps discovery alive, and
        // Minecraft has no connection to notice until login finishes, which over this
        // radio is long after the socket it would be judged by already exists.
        tunnelClients[id, default: 0] += 1
        if tunnelClients[id] == 1 {
            emit(["event": "inuse", "id": id])
        }

        liveConnections.append(client)
        client.stateUpdateHandler = { state in
            trace("tunnel.client: \(state)")
            switch state {
            case .cancelled, .failed:
                let left = (tunnelClients[id] ?? 1) - 1
                tunnelClients[id] = left > 0 ? left : nil
                if left <= 0 {
                    emit(["event": "idle", "id": id])
                }
            default:
                break
            }
        }

        client.start(queue: q)
        dial(id: id, for: client, candidates: candidates)
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            if let p = listener.port {
                emit(["event": "connected", "id": id, "localPort": Int(p.rawValue)])
            }
        case .failed(let e):
            tunnels[id] = nil
            listener.cancel()   // dropping the reference alone leaves it live
            emitError(e)
        default: break
        }
    }

    liveListeners.append(listener)
    listener.start(queue: q)
}

// MARK: - Commands

func handle(line: String) {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = obj["cmd"] as? String else { return }

    switch cmd {
    case "connect":
        if let id = obj["id"] as? String { q.async { connect(id: id) } }
    case "quit":
        exit(0)
    default:
        emit(["event": "error", "code": "unknown_command", "message": cmd])
    }
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

switch args.first {
case "host":
    guard let portStr = flag("--port"), let port = UInt16(portStr) else {
        emit(["event": "error", "code": "bad_args", "message": "host needs --port"])
        exit(2)
    }
    runHost(port: port, name: flag("--name") ?? "Minecraft", code: flag("--code") ?? "0000")
case "browse":
    runBrowse(autoConnect: args.contains("--auto"), match: flag("--match"))
default:
    FileHandle.standardError.write("usage: awdl-lan-helper host --port N [--name X] [--code NNNN] | browse [--auto] [--match NAME]\n".data(using: .utf8)!)
    exit(2)
}

// Parent death closes stdin. Exit rather than orphan a process holding the radio.
while let line = readLine(strippingNewline: true) {
    handle(line: line)
}
exit(0)
