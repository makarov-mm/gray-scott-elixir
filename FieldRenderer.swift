//  FieldRenderer.swift — GrayScottMetal
//  Uploads the latest V field into an r8Unorm texture and draws a
//  fullscreen triangle with a colormap fragment shader.

import Foundation
import Metal
import MetalKit

final class FieldRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private var texture: MTLTexture?
    private var pendingField: Data?
    private var pendingDims: (rows: Int, cols: Int) = (0, 0)
    private let lock = NSLock()

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "field_vertex"),
              let ffn = library.makeFunction(name: "field_fragment")
        else { return nil }

        self.device = device
        self.commandQueue = queue

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        else { return nil }
        self.pipeline = pipeline

        super.init()

        mtkView.device = device
        mtkView.delegate = self
        mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 1)
        mtkView.preferredFramesPerSecond = 60
    }

    /// Called from the network queue.
    func update(field: Data, rows: Int, cols: Int) {
        lock.lock()
        pendingField = field
        pendingDims = (rows, cols)
        lock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // upload the latest frame (render thread only)
        lock.lock()
        let field = pendingField
        let dims = pendingDims
        pendingField = nil
        lock.unlock()

        if let field, dims.rows > 0 {
            if texture == nil || texture!.width != dims.cols || texture!.height != dims.rows {
                let td = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r8Unorm,
                    width: dims.cols, height: dims.rows,
                    mipmapped: false)
                td.usage = .shaderRead
                texture = device.makeTexture(descriptor: td)
            }
            field.withUnsafeBytes { src in
                texture?.replace(region: MTLRegionMake2D(0, 0, dims.cols, dims.rows),
                                 mipmapLevel: 0,
                                 withBytes: src.baseAddress!,
                                 bytesPerRow: dims.cols)
            }
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        if let texture {
            let w = Float(view.drawableSize.width)
            let h = Float(view.drawableSize.height)
            let side = min(w, h)
            var viewScale = SIMD2<Float>(side / w, side / h)

            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&viewScale,
                               length: MemoryLayout<SIMD2<Float>>.stride,
                               index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
