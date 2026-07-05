//  GrayScottApp.swift — GrayScottMetal
//  SwiftUI shell. The simulation runs in an Elixir node — every strip
//  of the grid is a supervised GenServer. This app renders the field.
//
//  Keys:  K — chaos (kill a random strip process; the wound heals)
//         S — drop new seed spots
//
//  Run the server first:
//    cd server && ./run.zsh

import SwiftUI
import MetalKit

@main
struct GrayScottApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 700)
        }
    }
}

struct ContentView: View {
    @StateObject private var client = FieldClient()

    var body: some View {
        ZStack(alignment: .topLeading) {
            FieldMetalView(client: client)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 4) {
                Text("gray-scott \(client.dims.rows)x\(client.dims.cols)   [\(client.status)]")
                Text("K — kill a strip process (watch it heal)   S — new seeds")
                    .foregroundStyle(.secondary)
            }
            .font(.system(.body, design: .monospaced))
            .padding(10)
        }
        .onAppear {
            client.connect()
            client.installKeyMonitor()
        }
    }
}

struct FieldMetalView: NSViewRepresentable {
    let client: FieldClient

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        if let renderer = FieldRenderer(mtkView: view) {
            context.coordinator.renderer = renderer
            client.onFrame = { field, rows, cols in
                renderer.update(field: field, rows: rows, cols: cols)
            }
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: FieldRenderer?
    }
}
