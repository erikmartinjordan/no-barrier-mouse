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
    var onMessage: ((WireMessage, UInt64) -> Void)?

    private let serviceType = "_nobarriermouse._tcp"
    private let queue = DispatchQueue(label: "NoBarrierMouse.Network", qos: .userInteractive)
    private let codec = WireCodec()
    private let id = PeerIdentity.load()

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var heartbeatTimer: DispatchSourceTimer?
    private var nextPingID: UInt32 = 1
    private var role: WireMessage.PeerRole = .receiver
    private var state: ConnectionState = .off {
        didSet {
            guard oldValue != state else { return }
            DispatchQueue.main.async { self.onState?(self.state) }
        }
    }

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
        stopHeartbeat()
        browser = nil
        listener = nil
        connection = nil
        receiveBuffer.removeAll()
        InputMetrics.shared.setTransport("No transport")
        state = .off
    }

    func send(_ message: WireMessage) {
        guard let connection else { return }

        InputMetrics.shared.record(.tcpQueue, milliseconds: 0)
        let sendStartedAt = InputMetrics.nowTicks()
        let body = codec.encode(message)
        let length = UInt16(body.count)
        var packet = Data(capacity: 2 + body.count)
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            InputMetrics.shared.record(.tcpSendCompletion, from: sendStartedAt)
        })
        InputMetrics.shared.record(.tcpSerializeSend, from: sendStartedAt)
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
            guard let result = self.preferredResult(from: results) else { return }
            self.adopt(NWConnection(to: result.endpoint, using: self.makeParameters()), discoveredInterfaces: result.interfaces)
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

    private func adopt(_ candidate: NWConnection, discoveredInterfaces: [NWInterface] = []) {
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
        stopHeartbeat()
        updateTransport(candidate.currentPath, discoveredInterfaces: discoveredInterfaces)

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.updateTransport(candidate.currentPath, discoveredInterfaces: discoveredInterfaces)
                self.state = .connecting
                self.send(.hello(id: self.id, role: self.role))
                self.receive()
            case .failed, .cancelled:
                self.connection = nil
                self.stopHeartbeat()
                InputMetrics.shared.setTransport("Disconnected")
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
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, contentContext, complete, error in
            guard let self else { return }

            let receivedAt = InputMetrics.nowTicks()

            if !complete && error == nil {
                self.receive()
            }

            let callbackStartedAt = InputMetrics.nowTicks()

            if complete || error != nil {
                InputMetrics.shared.record(.receiveCallback, from: callbackStartedAt)
                self.connection?.cancel()
                self.connection = nil
                self.stopHeartbeat()
                self.state = self.listener == nil ? .off : .waiting
                return
            }

            if let data, !data.isEmpty {
                let decodeStartedAt = InputMetrics.nowTicks()
                receiveBuffer.append(data)
                var didDecode = false

                while let message = tryReadMessage() {
                    didDecode = true
                    if case .hello = message {
                        if state == .connecting {
                            state = .connected
                            startHeartbeat()
                        }
                    } else {
                        dispatchMessage(message, receivedAt: receivedAt)
                    }
                }

                if didDecode {
                    InputMetrics.shared.record(.tcpReceiveDecode, from: decodeStartedAt)
                }
            }

            InputMetrics.shared.record(.receiveCallback, from: callbackStartedAt)
        }
    }

    private func dispatchMessage(_ message: WireMessage, receivedAt: UInt64) {
        switch message {
        case .ping(let id, let sentAt):
            send(.pong(id: id, sentAt: sentAt))
        case .pong(_, let sentAt):
            InputMetrics.shared.record(.lanRTT, from: sentAt)
        default:
            onMessage?(message, receivedAt)
        }
    }

    private func tryReadMessage() -> WireMessage? {
        guard receiveBuffer.count >= 2 else { return nil }
        let length = Int(receiveBuffer[0]) | Int(receiveBuffer[1]) << 8
        guard receiveBuffer.count >= 2 + length else { return nil }
        defer { receiveBuffer.removeSubrange(0..<(2 + length)) }
        return codec.decode(from: Data(receiveBuffer[2..<(2 + length)]))
    }

    private func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.maximumSegmentSize = 512

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVoice
        return params
    }

    private func preferredResult(from results: Set<NWBrowser.Result>) -> NWBrowser.Result? {
        let candidates = results.filter { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return true }
            guard name != id else { return false }
            return id.localizedStandardCompare(name) == .orderedAscending
        }

        return candidates.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }.first
    }

    private func score(_ result: NWBrowser.Result) -> Int {
        let interfaces = result.interfaces
        if interfaces.contains(where: { $0.type == .wiredEthernet }) {
            return 300
        }
        if interfaces.contains(where: { $0.type == .wifi }) {
            return 240
        }
        if interfaces.contains(where: isDirectPeerInterface) {
            return 120
        }
        return 20
    }

    private func isDirectPeerInterface(_ interface: NWInterface) -> Bool {
        let name = interface.name.lowercased()
        return name.contains("awdl") || name.contains("llw") || name.contains("p2p")
    }

    private func updateTransport(_ path: NWPath?, discoveredInterfaces: [NWInterface]) {
        let label: String
        if path?.usesInterfaceType(.wiredEthernet) == true || discoveredInterfaces.contains(where: { $0.type == .wiredEthernet }) {
            label = "Ethernet"
        } else if path?.usesInterfaceType(.wifi) == true {
            label = "Router WiFi"
        } else if let direct = path?.availableInterfaces.first(where: isDirectPeerInterface)
            ?? discoveredInterfaces.first(where: isDirectPeerInterface) {
            label = "Direct peer WiFi (\(direct.name))"
        } else if path?.usesInterfaceType(.loopback) == true || discoveredInterfaces.contains(where: { $0.type == .loopback }) {
            label = "Loopback"
        } else {
            let names = discoveredInterfaces.map(\.name).joined(separator: ", ")
            label = names.isEmpty ? "Unknown transport" : "Transport \(names)"
        }

        InputMetrics.shared.setTransport(label)
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, self.state == .connected, self.connection != nil else { return }
            let id = self.nextPingID
            self.nextPingID &+= 1
            self.send(.ping(id: id, sentAt: InputMetrics.nowTicks()))
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
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
