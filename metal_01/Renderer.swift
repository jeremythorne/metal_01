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

class State {
    var dynamicUniformBuffer: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>
    var projectionMatrix: matrix_float4x4 = matrix_float4x4()
    var rotation: Float = 0
    public var frame: Float = 0
    
    init?(device: MTLDevice) {
        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        self.dynamicUniformBuffer = device.makeBuffer(
            length: uniformBufferSize,
            options: [MTLResourceOptions.storageModeShared])!

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents())
            .bindMemory(to: Uniforms.self, capacity: 1)
    }
    
    public func updateGameState() {
        /// Update any game state before rendering

        uniforms[0].projectionMatrix = projectionMatrix
        uniforms[0].time = frame / 60.0

        let rotationAxis = vector_float3(0, 1, 0)
        
        // with the lookat / perspective matrices we're using, obj models loaded
        // via MDLAsset are flipped on the xaxis, so flip back here
        
        let modelMatrix = matrix4x4_rotation(
            radians: rotation, axis: rotationAxis) * matrix4x4_scale(scale: vector_float3(-1, 1, 1))
        let viewMatrix = createViewMatrix(eyePosition: vector_float3(0, 2, -8), targetPosition: vector_float3(0, 2, 0),
                                           upVec: vector_float3(0, 1, 0))
        uniforms[0].modelMatrix = modelMatrix
        uniforms[0].viewMatrix = viewMatrix
        uniforms[0].modelViewMatrix = simd_mul(viewMatrix, modelMatrix)
        rotation += 0.01
        frame += 1
    }

    public func updateDynamicBufferState() {
        /// Update the state of our uniform buffers before rendering

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight

        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex

        uniforms = UnsafeMutableRawPointer(
            dynamicUniformBuffer.contents() + uniformBufferOffset
        ).bindMemory(to: Uniforms.self, capacity: 1)
    }

    public func updateAspect(aspect: Float) {
        projectionMatrix = createPerspectiveMatrix(fov:  toRadians(from: 65),
                                                   aspectRatio: aspect,
                                                   nearPlane: 0.1,
                                                   farPlane: 100)
        //projectionMatrix = createOrthographicProjection(-5, 5, -5, 5, 1, 20)
    }
    
    public func setUniforms(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setVertexBuffer(
            dynamicUniformBuffer, offset: uniformBufferOffset,
            index: BufferIndex.uniforms.rawValue)
        renderEncoder.setFragmentBuffer(
            dynamicUniformBuffer, offset: uniformBufferOffset,
            index: BufferIndex.uniforms.rawValue)
        renderEncoder.setMeshBuffer(
            dynamicUniformBuffer, offset: uniformBufferOffset,
            index: BufferIndex.uniforms.rawValue)
    }
}

class Demo {
    var depthState: MTLDepthStencilState

    @MainActor
    init?(metalKitView: MTKView, device: MTLDevice) {
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(
            descriptor: depthStateDescriptor)!
    }
    
    public func draw(in view: MTKView, commandBuffer: MTLCommandBuffer, state: State) {
        if let renderPassDescriptor = shadow_render_pass_descriptor() {
            if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPassDescriptor)
            {
                renderEncoder.setCullMode(.back)
                renderEncoder.setFrontFacing(.counterClockwise)
                renderEncoder.setDepthStencilState(depthState)
                state.setUniforms(renderEncoder: renderEncoder)
                
                draw_shadow(renderEncoder: renderEncoder)
                renderEncoder.endEncoding()
            }
        }
        /// Delay getting the currentRenderPassDescriptor until we absolutely need it to avoid
        ///   holding onto the drawable and blocking the display pipeline any longer than necessary
        let renderPassDescriptor = view.currentRenderPassDescriptor

        let clearColor = clear_color()

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
                state.setUniforms(renderEncoder: renderEncoder)

                draw_main(renderEncoder: renderEncoder)
                renderEncoder.popDebugGroup()
                renderEncoder.endEncoding()
             }
        }
    }

    func shadow_render_pass_descriptor() -> MTLRenderPassDescriptor? {
        return nil
    }

    func clear_color() -> MTLClearColor {
        return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    func draw_shadow(renderEncoder: MTLRenderCommandEncoder) {
    }

    func draw_main(renderEncoder: MTLRenderCommandEncoder) {
    }
}

class Renderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    let demos: [Demo]

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)

    let state: State
    
    @MainActor
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!
        self.commandQueue = self.device.makeCommandQueue()!

        metalKitView.depthStencilPixelFormat =
            MTLPixelFormat.depth32Float_stencil8
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.sampleCount = 1
        
        let houseRenderer = HouseRenderer(metalKitView: metalKitView, device: device)!
        let oceanRenderer = OceanRenderer(metalKitView: metalKitView, device: device)!
        let grassRenderer = GrassRenderer(metalKitView: metalKitView, device: device)!
       
        demos = [houseRenderer, oceanRenderer, grassRenderer]

        state = State(device:device)!
        
        super.init()
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

            state.updateDynamicBufferState()
            state.updateGameState()

            let demo_index = (Int(state.frame) / (60 * 30)) % demos.count
            let demo = demos[demo_index]
            demo.draw(in: view, commandBuffer: commandBuffer, state: state)
            
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        /// Respond to drawable size or orientation changes here
        let aspect = Float(size.width) / Float(size.height)
        state.updateAspect(aspect: aspect)
    }
}

