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

enum HouseRendererError: Error {
    case badVertexDescriptor
}

class ShadowLight {
    var light_direction: vector_float3
    var view_matrix: matrix_float4x4 = matrix_identity_float4x4
    var projection_matrix: matrix_float4x4 = matrix_identity_float4x4
    let pixel_format: MTLPixelFormat
    var shadow_texture: MTLTexture?
    var render_pass_descriptor: MTLRenderPassDescriptor?
    
    func calc_matrices() {
        view_matrix = createViewMatrix(eyePosition: -light_direction, targetPosition: vector_float3(0, 0, 0), upVec: vector_float3(0, 1, 0))
        projection_matrix = createOrthographicProjection(-15, 15, -15, 15, 1, 20)
    }
    
    func uniform() -> ShadowLightUniform {
        return ShadowLightUniform(projectionMatrix: projection_matrix, viewMatrix: view_matrix, direction: light_direction)
    }
    
    init(device: MTLDevice, light_direction: vector_float3) {
        self.light_direction = light_direction
        let shadowMapSize = 2048
        pixel_format = .depth32Float
        let textureDescriptor =
            MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixel_format,
                width: shadowMapSize,
                height: shadowMapSize,
                mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [ .renderTarget, .shaderRead ]
        shadow_texture = device.makeTexture(descriptor: textureDescriptor)
        render_pass_descriptor = MTLRenderPassDescriptor()
        render_pass_descriptor?.depthAttachment.texture = shadow_texture
        render_pass_descriptor?.depthAttachment.loadAction = .clear
        render_pass_descriptor?.depthAttachment.clearDepth = 1.0
        render_pass_descriptor?.depthAttachment.storeAction = .store        
    }
}


class HouseRenderer: Demo {

    public let device: MTLDevice
    var pipelineState: MTLRenderPipelineState
    var shadowPipeline: MTLRenderPipelineState
    var colorMap: MTLTexture
    var shadow_light: ShadowLight
    var mesh: MTKMesh

    @MainActor
    override init?(metalKitView: MTKView, device: MTLDevice) {
        self.device = device

        shadow_light = ShadowLight(device: device, light_direction: -vector_float3(8, 8, -8))
        shadow_light.calc_matrices()
        
        let mtlVertexDescriptor = HouseRenderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try HouseRenderer.buildRenderPipelineWithDevice(
                device: device,
                metalKitView: metalKitView,
                mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print(
                "Unable to compile render pipeline state.  Error info: \(error)"
            )
            return nil
        }

        do {
            shadowPipeline = try HouseRenderer.buildShadowPipelineWithDevice(
                device: device,
                metalKitView: metalKitView,
                mtlVertexDescriptor: mtlVertexDescriptor,
                pixelFormat: shadow_light.pixel_format
            )
        } catch {
            print(
                "Unable to compile render pipeline state.  Error info: \(error)"
            )
            return nil
        }

        do {
            mesh = try HouseRenderer.buildMesh(
                device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }

        do {
            colorMap = try HouseRenderer.loadTexture(
                device: device, textureName: "House")
        } catch {
            print("Unable to load texture. Error info: \(error)")
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
    class func buildRenderPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView,
        mtlVertexDescriptor: MTLVertexDescriptor
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "houseVertexShader")
        let fragmentFunction = library?.makeFunction(name: "houseFragmentShader")

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

    @MainActor
    class func buildShadowPipelineWithDevice(
        device: MTLDevice,
        metalKitView: MTKView,
        mtlVertexDescriptor: MTLVertexDescriptor,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {
        /// Build a render state pipeline object

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "houseVertexShadow")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.rasterSampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.depthAttachmentPixelFormat = pixelFormat

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
            throw HouseRendererError.badVertexDescriptor
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

    override func clear_color() -> MTLClearColor {
        return MTLClearColorMake(0.6, 0.6, 0.8, 1.0);
    }
  
    override func render_pass_descriptor(index: Int) -> MTLRenderPassDescriptor? {
        switch index {
        case 0:
            return shadow_light.render_pass_descriptor
        default:
            return nil
        }
    }
    
    override func draw_pass(renderEncoder: MTLRenderCommandEncoder, index: Int) {
        if index > 0 {
            return;
        }
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setRenderPipelineState(shadowPipeline)
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

        var shadow_uniform = shadow_light.uniform()
        
        renderEncoder.setVertexBytes(&shadow_uniform,
                                       length: MemoryLayout<ShadowLightUniform>.stride,
                                       index: BufferIndex.shadowLight.rawValue)
        
        for submesh in mesh.submeshes {
            renderEncoder.drawIndexedPrimitives(
                type: submesh.primitiveType,
                indexCount: submesh.indexCount,
                indexType: submesh.indexType,
                indexBuffer: submesh.indexBuffer.buffer,
                indexBufferOffset: submesh.indexBuffer.offset)
        }
    }
    
    override func draw_main(renderEncoder: MTLRenderCommandEncoder) {
        /// Per frame updates hare
        renderEncoder.setRenderPipelineState(pipelineState)

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

        var shadow_uniform = shadow_light.uniform()
        
        renderEncoder.setFragmentBytes(&shadow_uniform,
                                       length: MemoryLayout<ShadowLightUniform>.stride,
                                       index: BufferIndex.shadowLight.rawValue)
        renderEncoder.setFragmentTexture(shadow_light.shadow_texture,
                                         index: TextureIndex.shadowMap.rawValue)
        
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
    }
}

