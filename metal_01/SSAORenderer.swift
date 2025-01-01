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

enum SSAORendererError: Error {
    case badVertexDescriptor
}

class Gbuffer {
    var normalMap: MTLTexture?
    var depthMap: MTLTexture?
    var render_pass_descriptor: MTLRenderPassDescriptor?

    func update_size(device: MTLDevice, width: Float, height: Float) {
        let normalTextureDescriptor =
            MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: Int(width),
                height: Int(height),
                mipmapped: false)
        normalTextureDescriptor.storageMode = .private
        normalTextureDescriptor.usage = [ .renderTarget, .shaderRead ]

        let depthTextureDescriptor =
            MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: Int(width),
                height: Int(height),
                mipmapped: false)
        depthTextureDescriptor.storageMode = .private
        depthTextureDescriptor.usage = [ .renderTarget, .shaderRead ]
        
        normalMap = device.makeTexture(descriptor: normalTextureDescriptor)
        depthMap = device.makeTexture(descriptor: depthTextureDescriptor)
        render_pass_descriptor = MTLRenderPassDescriptor()
        render_pass_descriptor?.colorAttachments[0].texture = normalMap
        render_pass_descriptor?.colorAttachments[0].loadAction = .clear
        render_pass_descriptor?.colorAttachments[0].storeAction = .store
        render_pass_descriptor?.depthAttachment.texture = depthMap
        render_pass_descriptor?.depthAttachment.loadAction = .clear
        render_pass_descriptor?.depthAttachment.clearDepth = 1.0
        render_pass_descriptor?.depthAttachment.storeAction = .store
    }
}

class ScreenPass {
    let pixelFormat: MTLPixelFormat = .rgba8Unorm
    var map: MTLTexture?
    var render_pass_descriptor: MTLRenderPassDescriptor?

    func update_size(device: MTLDevice, width: Float, height: Float) {
        let textureDescriptor =
            MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: Int(width),
                height: Int(height),
                mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [ .renderTarget, .shaderRead ]
        
        map = device.makeTexture(descriptor: textureDescriptor)
        render_pass_descriptor = MTLRenderPassDescriptor()
        render_pass_descriptor?.colorAttachments[0].texture = map
        render_pass_descriptor?.colorAttachments[0].loadAction = .clear
        render_pass_descriptor?.colorAttachments[0].storeAction = .store
    }
}

func generate_noise(num_samples:Int) -> [vector_float3] {
    var noise: [vector_float3] = []
    for _ in 0..<num_samples {
        let sample = vector_float3(Float.random(in: -1..<1), Float.random(in: -1..<1), 0)
        noise.append(sample)
    }
    return noise
}

func mix(a: Float, b: Float, t: Float) -> Float {
    return a + (b-a) * t
}

func generate_samples(num_samples:Int) -> [vector_float3] {
    var samples: [vector_float3] = []
    for i in 0..<num_samples {
        var scale = Float(i) / Float(num_samples)
        scale = mix(a:0.1, b:1.0, t:scale * scale)
        var sample = vector_float3(Float.random(in: -1..<1), Float.random(in: -1..<1), Float.random(in: 0..<1))
        sample = normalize(sample) * Float.random(in: 0..<1) * scale
        samples.append(sample)
    }
    return samples
}

class SSAORenderer: Demo {
    
    public let device: MTLDevice
    var gbufferPipeline: MTLRenderPipelineState
    var ssaoPipeline: MTLRenderPipelineState
    var blurPipeline: MTLRenderPipelineState
    
    var gbuffer: Gbuffer
    var ssao_pass: ScreenPass
    var mesh: MTKMesh
    let samples_buffer: MTLBuffer?
    let noise_buffer: MTLBuffer?
    
    @MainActor
    override init?(metalKitView: MTKView, device: MTLDevice) {
        self.device = device
        
        gbuffer = Gbuffer()
        ssao_pass = ScreenPass()
        
        let mtlVertexDescriptor = SSAORenderer.buildMetalVertexDescriptor()
        
        let noise = generate_noise(num_samples: Int(NUM_NOISE_SAMPLES))
        let samples = generate_samples(num_samples: Int(NUM_SSAO_SAMPLES))
        samples_buffer = device.makeBuffer(bytes: samples,
                              length: MemoryLayout<vector_float3>.stride * samples.count)
        noise_buffer = device.makeBuffer(bytes: noise,
                          length: MemoryLayout<vector_float3>.stride * noise.count)
                
        do {
            gbufferPipeline = try SSAORenderer.buildGBufferPipelineWithDevice(
                device: device,
                metalKitView: metalKitView,
                mtlVertexDescriptor: mtlVertexDescriptor
            )
        } catch {
            print(
                "Unable to compile gbuffer pipeline state.  Error info: \(error)"
            )
            return nil
        }

        do {
            ssaoPipeline = try SSAORenderer.buildSSAOPipelineWithDevice(
                device: device,
                metalKitView: metalKitView,
                pixelFormat: ssao_pass.pixelFormat)
        } catch {
            print(
                "Unable to compile render pipeline state.  Error info: \(error)"
            )
            return nil
        }
        
        do {
            blurPipeline = try SSAORenderer.buildBlurPipelineWithDevice(
                device: device,
                metalKitView: metalKitView)
        } catch {
            print(
                "Unable to compile gbuffer pipeline state.  Error info: \(error)"
            )
            return nil
        }
        
        do {
            mesh = try SSAORenderer.buildMesh(
                device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }
        
        super.init(metalKitView: metalKitView, device: device)
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
        
        if let normal = mtlVertexDescriptor.attributes[VertexAttribute.normal.rawValue] {
            normal.format = MTLVertexFormat.float3
            normal.offset = 8
            normal.bufferIndex = BufferIndex.meshGenerics.rawValue
        }
        
        if let meshpos = mtlVertexDescriptor.layouts[BufferIndex.meshPositions.rawValue] {
            meshpos.stride = 12
            meshpos.stepRate = 1
            meshpos.stepFunction = MTLVertexStepFunction.perVertex
        }
        
        if let meshgenerics = mtlVertexDescriptor.layouts[BufferIndex.meshGenerics.rawValue] {
            meshgenerics.stride = 8 + 12
            meshgenerics.stepRate = 1
            meshgenerics.stepFunction = MTLVertexStepFunction.perVertex
        }
        
        return mtlVertexDescriptor
    }
    
    @MainActor
    class func buildSSAOPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object
        
        let library = device.makeDefaultLibrary()
        
        let vertexFunction = library?.makeFunction(name: "SSAOVertexShader")
        let fragmentFunction = library?.makeFunction(name: "SSAOFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat

        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }
    
    @MainActor
    class func buildBlurPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object
        
        let library = device.makeDefaultLibrary()
        
        let vertexFunction = library?.makeFunction(name: "BlurVertexShader")
        let fragmentFunction = library?.makeFunction(name: "BlurFragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "BlurPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        pipelineDescriptor.colorAttachments[0].pixelFormat =
            metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat =
            metalKitView.depthStencilPixelFormat
        
        
        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }
    
    @MainActor
    class func buildGBufferPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView,
        mtlVertexDescriptor: MTLVertexDescriptor
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object
        
        let library = device.makeDefaultLibrary()
        
        let vertexFunction = library?.makeFunction(name: "SSAOVertexGBuffer")
        let fragmentFunction = library?.makeFunction(name: "SSAOFragmentGBuffer")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "GBufferPipeline"
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }
    
    class func buildMesh(
        device: MTLDevice,
        mtlVertexDescriptor: MTLVertexDescriptor
    ) throws -> MTKMesh {
        /// Create and condition mesh data to feed into a pipeline using the given vertex descriptor
        
        let metalAllocator = MTKMeshBufferAllocator(device: device)
        
        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(
            mtlVertexDescriptor)
        if let pos = mdlVertexDescriptor.attributes[VertexAttribute.position.rawValue] as? MDLVertexAttribute {
            pos.name = MDLVertexAttributePosition
        }
        if let texcoord = mdlVertexDescriptor.attributes[VertexAttribute.texcoord.rawValue] as? MDLVertexAttribute {
            texcoord.name = MDLVertexAttributeTextureCoordinate
        }
        if let normal = mdlVertexDescriptor.attributes[VertexAttribute.normal.rawValue] as? MDLVertexAttribute {
            normal.name = MDLVertexAttributeNormal
        }
        
        let url = Bundle.main.url(
            forResource: "house",
            withExtension: "obj")
        
        let mdlAsset = MDLAsset(url: url,
                                vertexDescriptor: mdlVertexDescriptor,
                                bufferAllocator: metalAllocator)
        
        let meshes = mdlAsset.childObjects(of: MDLMesh.self) as? [MDLMesh]
        guard let mdlMesh = meshes?[0] else {
            fatalError("Did not find any meshes in the Model I/O asset")
        }
        
        guard
            let attributes = mdlVertexDescriptor.attributes
                as? [MDLVertexAttribute]
        else {
            throw SSAORendererError.badVertexDescriptor
        }
        attributes[VertexAttribute.position.rawValue].name =
        MDLVertexAttributePosition
        attributes[VertexAttribute.normal.rawValue].name =
        MDLVertexAttributeNormal
        attributes[VertexAttribute.texcoord.rawValue].name =
        MDLVertexAttributeTextureCoordinate
        
        mdlMesh.vertexDescriptor = mdlVertexDescriptor
        
        return try MTKMesh(mesh: mdlMesh, device: device)
    }
    
    override func clear_color() -> MTLClearColor {
        return MTLClearColorMake(0.6, 0.6, 0.8, 1.0);
    }
    
    override func render_pass_descriptor(index: Int) -> MTLRenderPassDescriptor? {
        switch index {
        case 0:
            return gbuffer.render_pass_descriptor
        case 1:
            return ssao_pass.render_pass_descriptor
        default:
            return nil
        }
    }
    
    func draw_gbuffer(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setRenderPipelineState(gbufferPipeline)
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
        
        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(
                type: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer,
                indexBufferOffset: submesh.indexBuffer.offset)
        }
    }
    
    func draw_ssao(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(ssaoPipeline)
        
        renderEncoder.setFragmentTexture(gbuffer.depthMap,
                                         index: TextureIndex.depthMap.rawValue)
        
        renderEncoder.setFragmentTexture(gbuffer.normalMap,
                                         index: TextureIndex.normalMap.rawValue)
                
        renderEncoder.setFragmentBuffer(noise_buffer, offset: 0, index: BufferIndex.noise.rawValue)
        renderEncoder.setFragmentBuffer(samples_buffer, offset: 0, index: BufferIndex.ssaoSamples.rawValue)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    }
    
    override func draw_pass(renderEncoder: MTLRenderCommandEncoder, index: Int) {
        switch index {
        case 0:
            draw_gbuffer(renderEncoder: renderEncoder)
        case 1:
            draw_ssao(renderEncoder: renderEncoder)
        default:
            return
        }
    }

    func draw_blur(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(blurPipeline)
        
        renderEncoder.setFragmentTexture(ssao_pass.map,
                                         index: TextureIndex.color.rawValue)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    override func draw_main(renderEncoder: MTLRenderCommandEncoder) {
        draw_blur(renderEncoder: renderEncoder)
    }
    
    override func update_size(width: Float, height: Float) {
        gbuffer.update_size(device: device, width: width, height: height)
        ssao_pass.update_size(device: device, width: width, height: height)
    }
}

