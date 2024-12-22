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
let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100

let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}

class Renderer: NSObject, MTKViewDelegate {

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

    var mesh: MTKMesh

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

        let mtlVertexDescriptor = Renderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(
                device: device,
                metalKitView: metalKitView,
                mtlVertexDescriptor: mtlVertexDescriptor)
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
            mesh = try Renderer.buildMesh(
                device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }

        do {
            colorMap = try Renderer.loadTexture(
                device: device, textureName: "ColorMap")
        } catch {
            print("Unable to load texture. Error info: \(error)")
            return nil
        }

        super.init()

    }

    class func buildMetalVertexDescriptor() -> MTLVertexDescriptor {
        // Create a Metal vertex descriptor specifying how vertices will by laid out for input into our render
        //   pipeline and how we'll layout our Model IO vertices

        let mtlVertexDescriptor = MTLVertexDescriptor()

        if let pos = mtlVertexDescriptor.attributes[VertexAttribute.position.rawValue] {
            pos.format = MTLVertexFormat.float3
            pos.offset = 0
            pos.bufferIndex = BufferIndex.meshPositions.rawValue
        }
        
        if let texcoord = mtlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue] {
            texcoord.format = MTLVertexFormat.float2
            texcoord.offset = 0
            texcoord.bufferIndex = BufferIndex.meshGenerics.rawValue
        }
    
        if let meshpos = mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue] {
            meshpos.stride = 12
            meshpos.stepRate = 1
            meshpos.stepFunction = MTLVertexStepFunction.perVertex
        }
        
        if let meshgenerics = mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue] {
            meshgenerics.stride = 8
            meshgenerics.stepRate = 1
            meshgenerics.stepFunction = MTLVertexStepFunction.perVertex
        }
        return mtlVertexDescriptor
    }

    @MainActor
    class func buildRenderPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView,
        mtlVertexDescriptor: MTLVertexDescriptor
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "vertexShader")
        let fragmentFunction = library?.makeFunction(name: "fragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat =
            metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat

        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }

    class func buildMesh(
        device: MTLDevice,
        mtlVertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor

        let metalAllocator = MTKMeshBufferAllocator(device: device)

        let mdlMesh = MDLMesh.newPlane(
            withDimensions: vector_float2(500, 500),
            segments: vector_uint2(200, 200),
            geometryType: MDLGeometryType.triangles,
            allocator: metalAllocator)

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(
            mtlVertexDescriptor)

        guard
            let attributes = mdlVertexDescriptor.attributes
                as? [MDLVertexAttribute]
        else {
            throw RendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name =
            MDLVertexAttributePosition
        attributes[VertexAttribute.texcoord.rawValue].name =
            MDLVertexAttributeTextureCoordinate

        mdlMesh.vertexDescriptor = mdlVertexDescriptor

        return try MTKMesh(mesh: mdlMesh, device: device)
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
                        MTLClearColorMake(0.6, 0.6, 0.8, 1.0);
                /// Final pass rendering code here
                if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
                    descriptor: renderPassDescriptor)
                {
                    renderEncoder.label = "Primary Render Encoder"

                    renderEncoder.pushDebugGroup("Draw Box")

                    renderEncoder.setCullMode(.back)

                    renderEncoder.setFrontFacing(.counterClockwise)

                    renderEncoder.setRenderPipelineState(pipelineState)

                    renderEncoder.setDepthStencilState(depthState)

                    renderEncoder.setVertexBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)
                    renderEncoder.setFragmentBuffer(
                        dynamicUniformBuffer, offset: uniformBufferOffset,
                        index: BufferIndex.uniforms.rawValue)

                    for (index, element) in mesh.vertexDescriptor.layouts
                        .enumerated()
                    {
                        guard let layout = element as? MDLVertexBufferLayout
                        else {
                            return
                        }

                        if layout.stride != 0 {
                            let buffer = mesh.vertexBuffers[index]
                            renderEncoder.setVertexBuffer(
                                buffer.buffer, offset: buffer.offset,
                                index: index)
                        }
                    }

                    renderEncoder.setFragmentTexture(
                        colorMap, index: TextureIndex.color.rawValue)

                    for submesh in mesh.submeshes {
                        renderEncoder.drawIndexedPrimitives(
                            type: submesh.primitiveType,
                            indexCount: submesh.indexCount,
                            indexType: submesh.indexType,
                            indexBuffer: submesh.indexBuffer.buffer,
                            indexBufferOffset: submesh.indexBuffer.offset)

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

// Generic matrix math utility functions
func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x
    let y = unitAxis.y
    let z = unitAxis.z
    return matrix_float4x4.init(
        columns: (
            vector_float4(
                ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
            vector_float4(
                x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
            vector_float4(
                x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
            vector_float4(0, 0, 0, 1)
        ))
}

func matrix4x4_translation(
    _ translationX: Float, _ translationY: Float, _ translationZ: Float
) -> matrix_float4x4 {
    return matrix_float4x4.init(
        columns: (
            vector_float4(1, 0, 0, 0),
            vector_float4(0, 1, 0, 0),
            vector_float4(0, 0, 1, 0),
            vector_float4(translationX, translationY, translationZ, 1)
        ))
}

func matrix_perspective_right_hand(
    fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float
) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4.init(
        columns: (
            vector_float4(xs, 0, 0, 0),
            vector_float4(0, ys, 0, 0),
            vector_float4(0, 0, zs, -1),
            vector_float4(0, 0, zs * nearZ, 0)
        ))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}
