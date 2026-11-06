//  FieldClient.swift — GrayScottMetal
//  TCP client for the Elixir gray_scott server.
//
//  Wire protocol (little-endian):
//    frame = rows :: UInt32, cols :: UInt32, rows*cols bytes (V field 0..255)
//
//  Commands to the server (single bytes):
//    0x01 — chaos: kill a random strip process
//    0x02 — seed: drop new V spots
//
//  The client reconnects on its own: start it before the server, or
//  restart the server while it runs, and it picks the stream up again.

import Foundation
import Network
import AppKit

final class FieldClient: ObservableObject {

    @Published var status: String = "connecting..."
    @Published var dims: (rows: Int, cols: Int) = (0, 0)
    @Published var framesReceived: Int = 0

    /// Raw field bytes + dimensions, called on the network queue.
    var onFrame: ((Data, Int, Int) -> Void)?

    private static let maxSide = 4096        // larger headers mean a corrupt stream
    private static let reconnectDelay = 1.0  // seconds

    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "field.net")
    private var keyMonitor: Any?
    private var host = "127.0.0.1"
    private var port: UInt16 = 4041
    private var reconnectScheduled = false

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        connection?.cancel()
    }

    /// K — chaos, S — seed. Lives here (a class) so the SwiftUI view
    /// needs no @State — avoids the SwiftUIMacros plugin dependency
    /// when building with bare swiftc.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "k": self?.sendChaos(); return nil
            case "s": self?.sendSeed(); return nil
            default:  return event
            }
        }
    }

    func connect(host: String = "127.0.0.1", port: UInt16 = 4041) {
        self.host = host
        self.port = port
        queue.async { self.open() }
    }

    func sendChaos() { send(byte: 0x01) }
    func sendSeed()  { send(byte: 0x02) }

    // MARK: - connection (network queue)

    private func open() {
        connection?.cancel()
        buffer.removeAll(keepingCapacity: true)
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            // Ignore late events from a connection that was already replaced
            guard let self, self.connection === conn else { return }
            switch state {
            case .ready:
                self.setStatus("connected")
            case .waiting(let error):
                // Typically "connection refused": the server is not up yet
                self.setStatus("waiting: \(error.localizedDescription)")
                self.scheduleReconnect()
            case .failed(let error):
                self.setStatus("failed: \(error.localizedDescription)")
                self.scheduleReconnect()
            case .cancelled:
                break
            default:
                break
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        queue.asyncAfter(deadline: .now() + Self.reconnectDelay) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.setStatus("reconnecting...")
            self.open()
        }
    }

    private func send(byte: UInt8) {
        connection?.send(content: Data([byte]),
                         completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: 1 << 18) { [weak self] data, _, isDone, error in
            guard let self, self.connection === conn else { return }
            if let data { self.buffer.append(data) }
            if !self.drainFrames() {
                self.setStatus("corrupt stream, reconnecting")
                self.scheduleReconnect()
                return
            }
            if isDone || error != nil {
                self.setStatus("disconnected")
                self.scheduleReconnect()
                return
            }
            self.receive(on: conn)
        }
    }

    /// Hands the newest complete frame to the renderer; older queued frames
    /// are dropped. Returns false when the header is implausible.
    private func drainFrames() -> Bool {
        var latest: (Data, Int, Int)? = nil
        var frames = 0
        while buffer.count >= 8 {
            let rows = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            })
            let cols = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            })
            guard rows > 0, cols > 0, rows <= Self.maxSide, cols <= Self.maxSide else { return false }
            let frameBytes = 8 + rows * cols
            guard buffer.count >= frameBytes else { break }
            latest = (buffer.subdata(in: 8 ..< frameBytes), rows, cols)
            buffer.removeSubrange(0 ..< frameBytes)
            frames += 1
        }
        if let (payload, rows, cols) = latest {
            onFrame?(payload, rows, cols)
            DispatchQueue.main.async {
                self.dims = (rows, cols)
                self.framesReceived += frames
            }
        }
        return true
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
