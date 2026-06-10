import Foundation
import Network

enum ConnectionState: Equatable {
    case off
    case waiting
    case connecting
    case connected
}

final class PeerNetwork {
    var onState: ((ConnectionState) -> Void)?
    var onMessage: ((WireMessage) -> Void)?

    private let serviceType = "_nobarriermouse._tcp"
    private let queue = DispatchQueue(label: "NoBarrierMouse.Network", qos: .userInteractive)
    private let codec = WireCodec()
    private let id = PeerIdentity.load()

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var role: WireMessage.PeerRole = .receiver
    private var state: ConnectionState = .off {
        didSet {
            guard oldValue != state else { return }
            DispatchQueue.main.async { self.onState?(self.state) }
        }
    }

    private static let udpPort: UInt16 = 51234
    private var udpListener: NWListener?
    private var udpConnection: NWConnection?

    func start(role: AppRole) {
        guard state == .off else { return }
        self.role = role == .controller ? .controller : .receiver
        state = .waiting
        startListener()
        startBrowser()
        scheduleBrowserRetry()
    }

    func stop() {
        browser?.cancel()
        listener?.cancel()
        connection?.cancel()
        udpConnection?.cancel()
        udpListener?.cancel()
        browser = nil
        listener = nil
        connection = nil
        udpConnection = nil
        udpListener = nil
        receiveBuffer.removeAll()
        state = .off
    }

    func send(_ message: WireMessage) {
        switch message {
        case .mouseDelta, .scroll:
            sendUDP(message)
        default:
            sendTCP(message)
        }
    }

    private func sendTCP(_ message: WireMessage) {
        guard let connection else { return }
        let body = codec.encode(message)
        let length = UInt16(body.count)
        var packet = Data(capacity: 2 + body.count)
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func sendUDP(_ message: WireMessage) {
        guard let udpConnection, udpConnection.state == .ready else {
            sendTCP(message)
            return
        }
        let data = codec.encode(message)
        udpConnection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startListener() {
        do {
            let params = makeParameters()
            let listener = try NWListener(using: params)
            listener.service = NWListener.Service(name: id, type: serviceType)
            listener.newConnectionHandler = { [weak self] incoming in
                self?.adopt(incoming)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            state = .off
        }
    }

    private func startBrowser() {
        let params = makeParameters()
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil else { return }
            guard let result = results.first(where: { result in
                if case .service(let name, _, _, _) = result.endpoint {
                    return name != self.id
                }
                return true
            }) else { return }

            if case .service(let name, _, _, _) = result.endpoint {
                guard self.id.localizedStandardCompare(name) == .orderedAscending else { return }
            }

            self.adopt(NWConnection(to: result.endpoint, using: params))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func scheduleBrowserRetry() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.state == .waiting, self.connection == nil else { return }
            self.browser?.cancel()
            self.browser = nil
            self.startBrowser()
            self.scheduleBrowserRetry()
        }
    }

    private func adopt(_ candidate: NWConnection) {
        if let connection {
            switch connection.state {
            case .setup, .preparing, .ready, .waiting:
                candidate.cancel()
                return
            case .failed, .cancelled:
                break
            @unknown default:
                break
            }
            connection.cancel()
        }

        connection = candidate
        receiveBuffer.removeAll()

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.state = .connecting
                self.send(.hello(id: self.id, role: self.role))
                self.receive()
            case .failed, .cancelled:
                self.connection = nil
                if self.listener != nil {
                    self.state = .waiting
                }
            default:
                break
            }
        }

        candidate.start(queue: queue)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                receiveBuffer.append(data)
                while let message = tryReadMessage() {
                    if case .hello = message {
                        if state == .connecting {
                            state = .connected
                            setupUDPChannel()
                        }
                    } else {
                        DispatchQueue.main.async { self.onMessage?(message) }
                    }
                }
            }

            if complete || error != nil {
                self.connection?.cancel()
                self.connection = nil
                self.state = self.listener == nil ? .off : .waiting
                return
            }

            self.receive()
        }
    }

    private func tryReadMessage() -> WireMessage? {
        guard receiveBuffer.count >= 2 else { return nil }
        let length = Int(receiveBuffer[0]) | Int(receiveBuffer[1]) << 8
        guard receiveBuffer.count >= 2 + length else { return nil }
        defer { receiveBuffer.removeSubrange(0..<(2 + length)) }
        return codec.decode(from: Data(receiveBuffer[2..<(2 + length)]))
    }

    private func setupUDPChannel() {
        guard let tcpConnection = connection else { return }

        if role == .controller {
            guard let host = peerHost(from: tcpConnection) else { return }
            let port = NWEndpoint.Port(integerLiteral: Self.udpPort)
            let udp = NWConnection(host: host, port: port, using: .udp)
            udp.stateUpdateHandler = { [weak self] state in
                if state == .ready {
                    self?.udpConnection = udp
                    self?.startReceivingUDP()
                }
            }
            udp.start(queue: queue)
        } else {
            let port = NWEndpoint.Port(integerLiteral: Self.udpPort)
            do {
                let params = NWParameters.udp
                let listener = try NWListener(using: params, on: port)
                listener.newConnectionHandler = { [weak self] incoming in
                    self?.udpConnection = incoming
                    self?.startReceivingUDP()
                }
                listener.start(queue: queue)
                udpListener = listener
            } catch {
                // UDP unavailable: fall back to TCP-only
            }
        }
    }

    private func startReceivingUDP() {
        udpConnection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            defer {
                if error == nil {
                    self.startReceivingUDP()
                }
            }
            guard let data, !data.isEmpty else { return }
            if let message = self.codec.decode(from: data) {
                DispatchQueue.main.async { self.onMessage?(message) }
            }
        }
    }

    private func peerHost(from connection: NWConnection) -> NWEndpoint.Host? {
        if let remote = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, _) = remote {
            return host
        }
        if case .hostPort(let host, _) = connection.endpoint {
            return host
        }
        return nil
    }

    private func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }
}

enum PeerIdentity {
    static func load() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: "PeerID"), !existing.isEmpty {
            return existing
        }

        let deviceName = Host.current().localizedName ?? "Mac"
        let id = "\(deviceName)-\(UUID().uuidString)"
        defaults.set(id, forKey: "PeerID")
        return id
    }
}
