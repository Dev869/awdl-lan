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

var peers: [String: NWEndpoint] = [:]
var pendingListeners: [String: NWListener] = [:]

func runBrowse(autoConnect: Bool, match: String?) {
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: p2pParameters())

    browser.browseResultsChangedHandler = { _, changes in
        for change in changes {
            switch change {
            case .added(let result):
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                peers[name] = result.endpoint
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
            case .removed(let result):
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                peers[name] = nil
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

func connect(id: String) {
    guard let endpoint = peers[id] else {
        emit(["event": "error", "code": "unknown_peer", "message": id])
        return
    }

    let peer = NWConnection(to: endpoint, using: p2pParameters())

    // Loopback only — nothing outside this machine should reach the tunnel mouth.
    let localParams = NWParameters.tcp
    localParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

    guard let listener = try? NWListener(using: localParams) else {
        emit(["event": "error", "code": "listener_failed", "message": "loopback bind failed"])
        return
    }
    pendingListeners[id] = listener

    listener.newConnectionHandler = { client in
        trace("connect: local client attached, dialling peer")
        watch(client, "tunnel.client")
        watch(peer, "tunnel.peer")
        client.start(queue: q)
        peer.start(queue: q)
        relay(client, peer)
        listener.cancel()               // one client per dial
        pendingListeners[id] = nil
    }

    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            if let p = listener.port {
                emit(["event": "connected", "id": id, "localPort": Int(p.rawValue)])
            }
        case .failed(let e): emitError(e)
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
