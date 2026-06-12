import CoreGraphics
import Darwin
import Foundation

final class RawSocketMouseBenchmarkServer: NSObject {
    var onMessage: ((WireMessage, UInt64) -> Void)?

    private let queue = DispatchQueue(label: "NoBarrierMouse.RawSocketBenchmark.Server", qos: .userInteractive)
    private let codec = WireCodec()
    private var listenFD: Int32 = -1
    private(set) var port: UInt16?
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private var service: NetService?

    func start() {
        queue.async {
            guard self.listenFD < 0 else { return }
            self.startOnQueue()
        }
    }

    func stop() {
        queue.async {
            self.service?.stop()
            self.service = nil
            self.listenSource?.cancel()
            self.listenSource = nil
            if self.listenFD >= 0 {
                close(self.listenFD)
                self.listenFD = -1
            }
            self.port = nil
            for (fd, source) in self.clientSources {
                source.cancel()
                close(fd)
            }
            self.clientSources.removeAll()
            self.buffers.removeAll()
        }
    }

    private func startOnQueue() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            return
        }

        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        publish(port: Int32(port ?? 0))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailableClients()
        }
        source.setCancelHandler {
            close(fd)
        }
        listenSource = source
        source.resume()
    }

    private func publish(port: Int32) {
        DispatchQueue.main.async {
            let service = NetService(domain: "local.", type: "_nbmbench._tcp.", name: Host.current().localizedName ?? "NoBarrierMouse", port: port)
            service.includesPeerToPeer = false
            service.publish(options: [])
            self.service = service
        }
    }

    private func acceptAvailableClients() {
        while true {
            var addr = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &length)
                }
            }
            if client < 0 {
                return
            }
            configureSocket(client)
            startReading(client)
        }
    }

    private func configureSocket(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func startReading(_ fd: Int32) {
        buffers[fd] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readAvailable(from: fd)
        }
        source.setCancelHandler {
            close(fd)
        }
        clientSources[fd] = source
        source.resume()
    }

    private func readAvailable(from fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &chunk, chunk.count)
        guard count > 0 else {
            closeClient(fd)
            return
        }

        let receivedAt = InputMetrics.nowTicks()
        buffers[fd, default: Data()].append(contentsOf: chunk.prefix(count))

        while let message = readMessage(from: fd) {
            onMessage?(message, receivedAt)
        }
    }

    private func readMessage(from fd: Int32) -> WireMessage? {
        guard var buffer = buffers[fd], buffer.count >= 2 else { return nil }
        let length = Int(buffer[0]) | Int(buffer[1]) << 8
        guard buffer.count >= 2 + length else { return nil }
        let body = Data(buffer[2..<(2 + length)])
        buffer.removeSubrange(0..<(2 + length))
        buffers[fd] = buffer
        return codec.decode(from: body)
    }

    private func closeClient(_ fd: Int32) {
        clientSources[fd]?.cancel()
        clientSources.removeValue(forKey: fd)
        buffers.removeValue(forKey: fd)
    }
}

final class RawSocketMouseBenchmarkClient: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let queue = DispatchQueue(label: "NoBarrierMouse.RawSocketBenchmark.Client", qos: .userInteractive)
    private let codec = WireCodec()
    private var browser: NetServiceBrowser?
    private var resolvingService: NetService?
    private var timer: DispatchSourceTimer?
    private var fd: Int32 = -1

    func run() {
        stop()
        let browser = NetServiceBrowser()
        browser.includesPeerToPeer = false
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_nbmbench._tcp.", inDomain: "local.")
    }

    func run(host: String, port: UInt16) {
        stop()
        queue.async {
            guard self.connect(host: host, port: port) else { return }
            self.sendPattern()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        browser?.stop()
        browser = nil
        resolvingService?.stop()
        resolvingService = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        browser.stop()
        resolvingService = service
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        queue.async {
            guard self.connect(to: sender) else { return }
            self.sendPattern()
        }
    }

    private func connect(to service: NetService) -> Bool {
        guard let addresses = service.addresses else { return false }
        for address in addresses {
            guard let candidate = openSocket(address: address) else { continue }
            fd = candidate
            return true
        }
        return false
    }

    private func connect(host: String, port: UInt16) -> Bool {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &result) == 0, let result else {
            return false
        }
        defer { freeaddrinfo(result) }

        var pointer: UnsafeMutablePointer<addrinfo>? = result
        while let info = pointer?.pointee {
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if fd >= 0 {
                var one: Int32 = 1
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                    self.fd = fd
                    return true
                }
                close(fd)
            }
            pointer = info.ai_next
        }
        return false
    }

    private func openSocket(address: Data) -> Int32? {
        let family = address.withUnsafeBytes { raw -> sa_family_t in
            raw.bindMemory(to: sockaddr.self).baseAddress?.pointee.sa_family ?? 0
        }
        guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { return nil }

        let fd = socket(Int32(family), SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let result = address.withUnsafeBytes { raw -> Int32 in
            guard let pointer = raw.bindMemory(to: sockaddr.self).baseAddress else { return -1 }
            return Darwin.connect(fd, pointer, socklen_t(address.count))
        }

        if result == 0 {
            return fd
        }
        close(fd)
        return nil
    }

    private func sendPattern() {
        guard fd >= 0 else { return }

        let id = UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: Double(UInt32.max)))
        let sampleRate: UInt16 = 120
        let sampleCount: UInt16 = 960
        let radius = 120.0
        let cycles = 4.0
        let startedAt = InputMetrics.nowTicks()
        var sequence: UInt32 = 0
        var previous = CGPoint(x: radius, y: 0)

        write(.benchmarkStart(id: id, sampleRate: sampleRate, sampleCount: sampleCount, transport: "Raw Socket TCP"))

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: 1.0 / Double(sampleRate), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard sequence < UInt32(sampleCount) else {
                self.write(.benchmarkEnd(id: id))
                self.stop()
                return
            }

            let progress = Double(sequence + 1) / Double(sampleCount)
            let angle = progress * cycles * Double.pi * 2
            let current = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            previous = current

            self.write(.benchmarkDelta(
                id: id,
                sequence: sequence,
                sentMilliseconds: InputMetrics.milliseconds(from: startedAt),
                dx: dx,
                dy: dy
            ))
            sequence += 1
        }
        self.timer = timer
        timer.resume()
    }

    private func write(_ message: WireMessage) {
        guard fd >= 0 else { return }
        let body = codec.encode(message)
        var packet = Data(capacity: 2 + body.count)
        let length = UInt16(body.count)
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(body)
        packet.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < packet.count {
                let n = Darwin.write(fd, base.advanced(by: sent), packet.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
