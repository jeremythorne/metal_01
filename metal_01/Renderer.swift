//
//  Renderer.swift
//  metal_01
//
//  Created by Jeremy Thorne on 20/12/2024.
//

// Our platform independent renderer class

import Metal
import MetalKit
import simd

// The 256 byte aligned size of our uniform structure
fileprivate let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100

fileprivate let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

class Renderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    let oceanRenderer: OceanRenderer
    let grassRenderer: GrassRenderer
    
    var dynamicUniformBuffer: MTLBuffer
    var depthState: MTLDepthStencilState

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    var uniformBufferOffset = 0

    var uniformBufferIndex = 0

    var uniforms: UnsafeMutablePointer<Uniforms>

    var projectionMatrix: matrix_float4x4 = matrix_float4x4()

    var rotation: Float = 0
    var frame: Float = 0

    @MainActor
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!
        self.commandQueue = self.device.makeCommandQueue()!

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = self.device.makeBuffer(
            length: uniformBufferSize,
            options: [MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents())
            .bindMemory(to: Uniforms.self, capacity: 1)

        metalKitView.depthStencilPixelFormat =
            MTLPixelFormat.depth32Float_stencil8
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.sampleCount = 1
        
        oceanRenderer = OceanRenderer(metalKitView: metalKitView)!
        grassRenderer = GrassRenderer(metalKitView: metalKitView)!

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(
            descriptor: depthStateDescriptor)!

        super.init()

    }

    private func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex

        uniforms = UnsafeMutableRawPointer(
            dynamicUniformBuffer.contents() + uniformBufferOffset
        ).bindMemory(to: Uniforms.self, capacity: 1)
    }

    private func updateGameState() {
        /// Update any game state before rendering

        uniforms[0].projectionMatrix = projectionMatrix
        uniforms[0].time = frame / 60.0

        let rotationAxis = vector_float3(0, 1, 0)
        let modelMatrix = matrix4x4_rotation(
            radians: rotation, axis: rotationAxis)
        let viewMatrix = matrix4x4_translation(0.0, -2.0, -8.0)
        uniforms[0].modelViewMatrix = simd_mul(viewMatrix, modelMatrix)
        rotation += 0.01
        frame += 1
    }

    func draw(in view: MTKView) {
        /// Per frame updates hare

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        if let commandBuffer = commandQueue.makeCommandBuffer() {
            let semaphore = inFlightSemaphore
            commandBuffer.addCompletedHandler {
                (_ commandBuffer) -> Swift.Void in
                semaphore.signal()
            }

            self.updateDynamicBufferState()

            self.updateGameState()

            let demo_index = (Int(frame) / (60 * 30)) % 2
            /// Delay getting the currentRenderPassDescriptor until we absolutely need it to avoid
            ///   holding onto the drawable and blocking the display pipeline any longer than necessary
            let renderPassDescriptor = view.currentRenderPassDescriptor

            let clearColor = switch(demo_index) {
            case 0:
                oceanRenderer.clearColor()
            default:
                grassRenderer.clearColor()
            }
            
            if let renderPassDescriptor = renderPassDescriptor {
                renderPassDescriptor.colorAttachments[0].clearColor = clearColor;
                /// Final pass rendering code here
                if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPassDescriptor)
                {
                    renderEncoder.label = "Primary Render Encoder"

                    renderEncoder.pushDebugGroup("Draw Box")

                    renderEncoder.setCullMode(.back)

                    renderEncoder.setFrontFacing(.counterClockwise)

                    renderEncoder.setDepthStencilState(depthState)

                    renderEncoder.setVertexBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setFragmentBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setMeshBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    
                    switch demo_index {
                    case 0:
                        oceanRenderer.draw(in: view, renderEncoder: renderEncoder)
                    default:
                        grassRenderer.draw(in: view, renderEncoder: renderEncoder)
                    }

                    renderEncoder.popDebugGroup()

                    renderEncoder.endEncoding()
                    
                    if let drawable = view.currentDrawable {
                        commandBuffer.present(drawable)
                    }
                 }
            }
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        /// Respond to drawable size or orientation changes here

        let aspect = Float(size.width) / Float(size.height)
        projectionMatrix = matrix_perspective_right_hand(
            fovyRadians: radians_from_degrees(65), aspectRatio: aspect,
            nearZ: 0.1, farZ: 100.0)
    }
}

