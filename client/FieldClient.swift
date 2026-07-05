//  FieldClient.swift — GrayScottMetal
//  TCP client for the Elixir gray_scott server.
//
//  Wire protocol (little-endian):
//    frame = rows :: UInt32, cols :: UInt32, rows*cols bytes (V field 0..255)
//
//  Commands to the server (single bytes):
//    0x01 — chaos: kill a random strip process
//    0x02 — seed: drop new V spots

import Foundation
import Network
import AppKit

final class FieldClient: ObservableObject {

    @Published var status: String = "connecting..."
    @Published var dims: (rows: Int, cols: Int) = (0, 0)

    /// Raw field bytes + dimensions, called on an arbitrary queue.
    var onFrame: ((Data, Int, Int) -> Void)?

    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "field.net")
    private var keyMonitor: Any?

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!,
                                using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:          self?.status = "connected"
                case .waiting(let e): self?.status = "waiting: \(e)"
                case .failed(let e):  self?.status = "failed: \(e)"
                case .cancelled:      self?.status = "cancelled"
                default:              break
                }
            }
        }
        conn.start(queue: queue)
        receive()
    }

    func sendChaos() { send(byte: 0x01) }
    func sendSeed()  { send(byte: 0x02) }

    private func send(byte: UInt8) {
        connection?.send(content: Data([byte]),
                         completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1,
                            maximumLength: 1 << 18) { [weak self] data, _, isDone, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drainFrames()
            if isDone || error != nil {
                DispatchQueue.main.async { self.status = "disconnected" }
                return
            }
            self.receive()
        }
    }

    private func drainFrames() {
        var latest: (Data, Int, Int)? = nil
        while buffer.count >= 8 {
            let rows = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            })
            let cols = Int(buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            })
            let frameBytes = 8 + rows * cols
            guard buffer.count >= frameBytes else { break }
            latest = (buffer.subdata(in: 8 ..< frameBytes), rows, cols)
            buffer.removeSubrange(0 ..< frameBytes)
        }
        if let (payload, rows, cols) = latest {
            onFrame?(payload, rows, cols)
            DispatchQueue.main.async { self.dims = (rows, cols) }
        }
    }
}
