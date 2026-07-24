import Darwin
import Foundation
import Network
import SystemConfiguration

// MARK: - Connection path

final class ConnectionMonitor: @unchecked Sendable {
    @MainActor var onChange: (@MainActor @Sendable (ConnectionState) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.nishantkumar.speedbar.path")
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let state = Self.connectionState(from: path)
            Task { @MainActor [weak self] in
                self?.onChange?(state)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    private static func connectionState(from path: NWPath) -> ConnectionState {
        let availability: ConnectionAvailability
        switch path.status {
        case .satisfied:
            availability = .online
        case .requiresConnection:
            availability = .connecting
        case .unsatisfied:
            availability = .offline
        @unknown default:
            availability = .checking
        }

        let interface = activeInterface(for: path)
        return ConnectionState(
            availability: availability,
            interfaceName: interface?.name,
            interfaceLabel: label(for: interface),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private static func activeInterface(for path: NWPath) -> NWInterface? {
        let orderedTypes: [NWInterface.InterfaceType] = [
            .other,
            .wifi,
            .wiredEthernet,
            .cellular
        ]

        for type in orderedTypes where path.usesInterfaceType(type) {
            let candidates = path.availableInterfaces.filter { $0.type == type && $0.name != "lo0" }
            if type == .other, let tunnel = candidates.first(where: { $0.name.hasPrefix("utun") }) {
                return tunnel
            }
            if let first = candidates.first {
                return first
            }
        }
        return nil
    }

    private static func label(for interface: NWInterface?) -> String {
        guard let interface else { return "Active network" }
        switch interface.type {
        case .wifi: return "Wi‑Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Local"
        case .other:
            return interface.name.hasPrefix("utun") ? "VPN" : "Other network"
        @unknown default:
            return "Active network"
        }
    }
}

// MARK: - Live interface traffic

final class NetworkMonitor {
    private struct CounterSample {
        let interfaceName: String
        let received: UInt64
        let sent: UInt64
        let uptime: TimeInterval
    }

    private var previousSample: CounterSample?

    func getSpeed(interfaceName: String?) -> ThroughputSample {
        guard let resolvedName = interfaceName ?? primaryInterfaceName(),
              let counters = counters(for: resolvedName) else {
            previousSample = nil
            return .zero
        }

        let now = ProcessInfo.processInfo.systemUptime
        let current = CounterSample(
            interfaceName: resolvedName,
            received: counters.received,
            sent: counters.sent,
            uptime: now
        )
        defer { previousSample = current }

        guard let previous = previousSample,
              previous.interfaceName == current.interfaceName else {
            return .zero
        }

        let elapsed = current.uptime - previous.uptime
        guard elapsed > 0, elapsed < 10,
              current.received >= previous.received,
              current.sent >= previous.sent else {
            return .zero
        }

        return ThroughputSample(
            downloadBytesPerSecond: Double(current.received - previous.received) / elapsed,
            uploadBytesPerSecond: Double(current.sent - previous.sent) / elapsed
        )
    }

    func reset() {
        previousSample = nil
    }

    private func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil,
            "SpeedBar.InterfaceLookup" as CFString,
            nil,
            nil
        ) else {
            return nil
        }

        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString),
                  let dictionary = value as? [String: Any],
                  let name = dictionary["PrimaryInterface"] as? String,
                  !name.isEmpty else {
                continue
            }
            return name
        }
        return nil
    }

    private func counters(for interfaceName: String) -> (received: UInt64, sent: UInt64)? {
        let interfaceIndex = if_nametoindex(interfaceName)
        guard interfaceIndex != 0 else { return nil }

        var mib: [Int32] = [
            CTL_NET,
            PF_ROUTE,
            0,
            0,
            NET_RT_IFLIST2,
            Int32(interfaceIndex)
        ]
        var requiredSize = 0

        let sizeResult = mib.withUnsafeMutableBufferPointer { mibBuffer in
            sysctl(
                mibBuffer.baseAddress,
                u_int(mibBuffer.count),
                nil,
                &requiredSize,
                nil,
                0
            )
        }
        guard sizeResult == 0, requiredSize >= MemoryLayout<if_msghdr2>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: requiredSize)
        let readResult = mib.withUnsafeMutableBufferPointer { mibBuffer in
            buffer.withUnsafeMutableBytes { rawBuffer in
                sysctl(
                    mibBuffer.baseAddress,
                    u_int(mibBuffer.count),
                    rawBuffer.baseAddress,
                    &requiredSize,
                    nil,
                    0
                )
            }
        }
        guard readResult == 0 else { return nil }

        return buffer.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            var offset = 0

            while offset + 4 <= requiredSize {
                let messageAddress = baseAddress.advanced(by: offset)
                let messageLength = Int(
                    messageAddress.assumingMemoryBound(to: UInt16.self).pointee
                )
                guard messageLength > 0, offset + messageLength <= requiredSize else {
                    break
                }

                let messageType = messageAddress.load(fromByteOffset: 3, as: UInt8.self)
                if Int32(messageType) == RTM_IFINFO2,
                   messageLength >= MemoryLayout<if_msghdr2>.size {
                    let info = messageAddress.assumingMemoryBound(to: if_msghdr2.self).pointee
                    return (
                        received: UInt64(info.ifm_data.ifi_ibytes),
                        sent: UInt64(info.ifm_data.ifi_obytes)
                    )
                }
                offset += messageLength
            }
            return nil
        }
    }
}

// MARK: - Latency probes and history

private final class LatencyProbe: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let timeoutInterval: TimeInterval
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var timeoutWorkItem: DispatchWorkItem?
    private var completion: (@Sendable (LatencyMeasurement) -> Void)?
    private var hasFinished = false

    init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        timeout: TimeInterval,
        queue: DispatchQueue,
        completion: @escaping @Sendable (LatencyMeasurement) -> Void
    ) {
        self.queue = queue
        self.timeoutInterval = timeout
        self.connection = NWConnection(host: host, port: port, using: .tcp)
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.finish(with: .timedOut)
        }
        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
        connection.start(queue: queue)
    }

    func cancelSilently() {
        completion = nil
        cleanUp()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            finish(with: .success(milliseconds: max(0, elapsed * 1_000)))
        case .failed, .cancelled:
            finish(with: .timedOut)
        default:
            break
        }
    }

    private func finish(with measurement: LatencyMeasurement) {
        guard !hasFinished else { return }
        hasFinished = true
        let callback = completion
        completion = nil
        cleanUp()
        callback?(measurement)
    }

    private func cleanUp() {
        guard !hasFinished || timeoutWorkItem != nil || connection.stateUpdateHandler != nil else {
            return
        }
        hasFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

final class LatencyMonitor: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (LatencyMeasurement) -> Void

    @MainActor private(set) var history: [LatencyPoint] = []

    private let maxHistoryDuration: TimeInterval = 300
    private let queue = DispatchQueue(label: "com.nishantkumar.speedbar.latency")
    private let probeTimeout: TimeInterval = 0.85
    private var activeProbe: LatencyProbe?
    private var probeGeneration = 0

    func measureLatency(isOnline: Bool, completion: @escaping Completion) {
        guard isOnline else {
            Task { @MainActor in completion(.offline) }
            return
        }

        queue.async { [weak self] in
            guard let self, self.activeProbe == nil else { return }

            self.probeGeneration += 1
            let generation = self.probeGeneration
            let probe = LatencyProbe(
                host: "1.1.1.1",
                port: 443,
                timeout: self.probeTimeout,
                queue: self.queue
            ) { [weak self] measurement in
                guard let self, self.probeGeneration == generation else { return }
                self.activeProbe = nil
                Task { @MainActor in
                    completion(measurement)
                }
            }
            self.activeProbe = probe
            probe.start()
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.probeGeneration += 1
            self.activeProbe?.cancelSilently()
            self.activeProbe = nil
        }
    }

    @MainActor
    func record(_ measurement: LatencyMeasurement, at timestamp: Date = Date()) {
        history.append(LatencyPoint(timestamp: timestamp, measurement: measurement))
        pruneOldData(now: timestamp)
    }

    @MainActor
    func getRecentHistory(now: Date = Date()) -> [LatencyPoint] {
        pruneOldData(now: now)
        return history
    }

    @MainActor
    private func pruneOldData(now: Date) {
        let cutoff = now.addingTimeInterval(-maxHistoryDuration)
        history.removeAll { $0.timestamp < cutoff }
    }
}
