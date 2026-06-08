import Foundation
import Network

enum ConnectionState: Equatable {
    case off
    case waiting
    case connected
}

final class PeerNetwork {
    var onState: ((ConnectionState) -> Void)?
    var onMessage: ((WireMessage) -> Void)?

    private let serviceType = "_nobarriermouse._tcp"
    private let queue = DispatchQueue(label: "NoBarrierMouse.Network", qos: .userInteractive)
    private let codec = LineCodec()
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

    func start(role: AppRole) {
        guard state == .off else { return }
        self.role = role == .controller ? .controller : .receiver
        state = .waiting
        startListener()
        startBrowser()
    }

    func stop() {
        browser?.cancel()
        listener?.cancel()
        connection?.cancel()
        browser = nil
        listener = nil
        connection = nil
        receiveBuffer.removeAll()
        state = .off
    }

    func send(_ message: WireMessage) {
        guard let data = codec.encode(message), let connection else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
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

            self.adopt(NWConnection(to: result.endpoint, using: params))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func adopt(_ candidate: NWConnection) {
        if let connection {
            connection.cancel()
        }

        connection = candidate
        receiveBuffer.removeAll()

        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.state = .connected
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
                for message in self.codec.decodeLines(from: data, buffer: &self.receiveBuffer) {
                    DispatchQueue.main.async { self.onMessage?(message) }
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

    private func makeParameters() -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.includePeerToPeer = true
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
