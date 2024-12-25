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

enum GrassRendererError: Error {
    case badVertexDescriptor
}

class GrassRenderer: NSObject, MTKViewDelegate {

    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    var colorMap: MTLTexture

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

        do {
            (self.pipelineState, _) = try GrassRenderer.buildRenderPipelineWithDevice(
                device: device,
                metalKitView: metalKitView)
        } catch {
            print(
                "Unable to compile render pipeline state.  Error info: \(error)"
            )
            return nil
        }

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.less
        depthStateDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(
            descriptor: depthStateDescriptor)!

        do {
            colorMap = try GrassRenderer.loadTexture(
                device: device, textureName: "Leaf")
        } catch {
            print("Unable to load texture. Error info: \(error)")
            return nil
        }

        super.init()

    }

    @MainActor
    class func buildRenderPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView
    ) throws -> (MTLRenderPipelineState, MTLRenderPipelineReflection?) {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let objectFunction = library?.makeFunction(name: "grass_object_shader")
        let meshFunction = library?.makeFunction(name: "grass_mesh_shader")
        let fragmentFunction = library?.makeFunction(name: "grass_fragment_shader")

        let pipelineDescriptor = MTLMeshRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.objectFunction = objectFunction
        pipelineDescriptor.meshFunction = meshFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        pipelineDescriptor.colorAttachments[0].pixelFormat =
            metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat
        
        if let colorAtt = pipelineDescriptor.colorAttachments[0] {
            colorAtt.isBlendingEnabled = true
            colorAtt.rgbBlendOperation = MTLBlendOperation.add
            colorAtt.alphaBlendOperation = MTLBlendOperation.add
            colorAtt.sourceRGBBlendFactor = MTLBlendFactor.sourceAlpha
            colorAtt.sourceAlphaBlendFactor = MTLBlendFactor.sourceAlpha
            colorAtt.destinationRGBBlendFactor = MTLBlendFactor.oneMinusSourceAlpha
            colorAtt.destinationAlphaBlendFactor = MTLBlendFactor.oneMinusSourceAlpha
        }

        return try device.makeRenderPipelineState (
            descriptor: pipelineDescriptor, options: MTLPipelineOption())
    }

    class func loadTexture(
        device: MTLDevice,
        textureName: String
    ) throws -> MTLTexture {
        /// Load texture data with optimal parameters for sampling

        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(
                value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(
                value: MTLStorageMode.`private`.rawValue),
        ]

        return try textureLoader.newTexture(
            name: textureName,
            scaleFactor: 1.0,
            bundle: nil,
            options: textureLoaderOptions)

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

            /// Delay getting the currentRenderPassDescriptor until we absolutely need it to avoid
            ///   holding onto the drawable and blocking the display pipeline any longer than necessary
            let renderPassDescriptor = view.currentRenderPassDescriptor

            if let renderPassDescriptor = renderPassDescriptor {
                renderPassDescriptor.colorAttachments[0].clearColor =
                MTLClearColorMake(0.0, 0.1, 0.0, 1.0);
                /// Final pass rendering code here
                if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPassDescriptor)
                {
                    renderEncoder.label = "Primary Render Encoder"

                    renderEncoder.pushDebugGroup("Draw Box")

                    //renderEncoder.setCullMode(.back)

                    //renderEncoder.setFrontFacing(.counterClockwise)

                    renderEncoder.setRenderPipelineState(pipelineState)

                    renderEncoder.setDepthStencilState(depthState)

                    renderEncoder.setObjectBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setMeshBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setFragmentBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setFragmentTexture(
                        colorMap, index: TextureIndex.color.rawValue)
                    for i in 0..<5 {
                        for j in 0...5 {
                            var offset = vector_float2(Float(i) * 16.0 - 8.0, Float(j) * 16.0 - 8.0);
        
                            renderEncoder.setMeshBytes(&offset,
                                                       length: MemoryLayout<vector_float2>.stride,
                                                       index: BufferIndex.meshBytes.rawValue)

                            renderEncoder.drawMeshThreadgroups(MTLSizeMake(1, 1, 1),
                                    threadsPerObjectThreadgroup: MTLSizeMake(Int(OBJECT_THREADS_PER_THREADGROUP), 1, 1),
                                    threadsPerMeshThreadgroup: MTLSizeMake(Int(MESH_THREADS_PER_THREADGROUP), 1, 1)
                                    )
                            
                        }
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

