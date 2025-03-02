//
//  EnvRenderer.swift
//  metal_01
//
//  Created by Jeremy Thorne on 20/12/2024.
//

// Rendering with an HDRI environment

import Metal
import MetalKit
import simd

// The 256 byte aligned size of our uniform structure
fileprivate let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100

fileprivate let maxBuffersInFlight = 3

enum EnvRendererError: Error {
    case badVertexDescriptor
}

// Render 6 faces of a cube map from a sphere texture
class CubeFromSphere {
    let pixel_format: MTLPixelFormat
    var texture: MTLTexture?
    var pipeline: MTLRenderPipelineState
    
    class func buildRenderPipelineWithDevice(
        device: MTLDevice,
        pixel_format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "cubeFromSphereVertexShader")
        let fragmentFunction = library?.makeFunction(name: "cubeFromSphereFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "CubeFromSpherePipeline"
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        for i in 0..<6 {
            pipelineDescriptor.colorAttachments[i].pixelFormat = pixel_format
        }

        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }
   
    func render_pass_descriptor() -> MTLRenderPassDescriptor? {
        let render_pass_descriptor = MTLRenderPassDescriptor()
        for i in 0..<6 {
            if let desc = render_pass_descriptor.colorAttachments[i] {
                desc.texture =
                texture?.makeTextureView(
                    pixelFormat: pixel_format,
                    textureType: .type2D,
                    levels:0..<1, slices: i..<(i + 1))
                desc.loadAction = .clear
                desc.storeAction = .store
                desc.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
            }
        }
        return render_pass_descriptor
    }
    
    func draw_pass(renderEncoder: MTLRenderCommandEncoder, sphereTexture: MTLTexture) {
        renderEncoder.setRenderPipelineState(pipeline)
        
        renderEncoder.setFragmentTexture(sphereTexture,
                                         index: TextureIndex.color.rawValue)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    
    init?(device: MTLDevice) {
        let mapSize = 512
        pixel_format = .rgba32Float
        let textureDescriptor =
        MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: pixel_format,
                size: mapSize,
                mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [ .renderTarget, .shaderRead ]
        texture = device.makeTexture(descriptor: textureDescriptor)
        do {
            pipeline = try CubeFromSphere.buildRenderPipelineWithDevice(device: device,
                                                 pixel_format: pixel_format)
        } catch {
            print(
                "Unable to compile cubefromsphere pipeline state.  Error info: \(error)"
            )
            return nil
        }
    }
}

// Render 6 faces of a diffuse irradiance cube map from hdri cube map
class DiffuseCube {
    let pixel_format: MTLPixelFormat
    var texture: MTLTexture?
    var pipeline: MTLRenderPipelineState
    
    class func buildRenderPipelineWithDevice(
        device: MTLDevice,
        pixel_format: MTLPixelFormat
    ) throws -> MTLRenderPipelineState {

        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "diffuseCubeVertexShader")
        let fragmentFunction = library?.makeFunction(name: "diffuseCubeFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "DiffuseCubePipeline"
        pipelineDescriptor.rasterSampleCount = 1
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        for i in 0..<6 {
            pipelineDescriptor.colorAttachments[i].pixelFormat = pixel_format
        }

        return try device.makeRenderPipelineState(
            descriptor: pipelineDescriptor)
    }
   
    func render_pass_descriptor() -> MTLRenderPassDescriptor? {
        let render_pass_descriptor = MTLRenderPassDescriptor()
        for i in 0..<6 {
            if let desc = render_pass_descriptor.colorAttachments[i] {
                desc.texture =
                texture?.makeTextureView(
                    pixelFormat: pixel_format,
                    textureType: .type2D,
                    levels:0..<1, slices: i..<(i + 1))
                desc.loadAction = .clear
                desc.storeAction = .store
                desc.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
            }
        }
        return render_pass_descriptor
    }
    
    func draw_pass(renderEncoder: MTLRenderCommandEncoder, hdriTexture: MTLTexture) {
        renderEncoder.setRenderPipelineState(pipeline)
        
        renderEncoder.setFragmentTexture(hdriTexture,
                                         index: TextureIndex.color.rawValue)
        
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    
    init?(device: MTLDevice) {
        let mapSize = 32
        pixel_format = .rgba32Float
        let textureDescriptor =
        MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: pixel_format,
                size: mapSize,
                mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [ .renderTarget, .shaderRead ]
        texture = device.makeTexture(descriptor: textureDescriptor)
        do {
            pipeline = try DiffuseCube.buildRenderPipelineWithDevice(device: device,
                                                 pixel_format: pixel_format)
        } catch {
            print(
                "Unable to compile diffuse cube pipeline state.  Error info: \(error)"
            )
            return nil
        }
    }
}

class EnvRenderer: Demo {

    public let device: MTLDevice
    var pipelineState: MTLRenderPipelineState
    var colorMap: MTLTexture
    var mesh: MTKMesh
    var cube_from_sphere: CubeFromSphere
    var diffuse_cube: DiffuseCube

    @MainActor
    override init?(metalKitView: MTKView, device: MTLDevice) {
        self.device = device

        let mtlVertexDescriptor = EnvRenderer.buildMetalVertexDescriptor()

        guard let cfs = CubeFromSphere(device: device)
        else {
            return nil
        }
        cube_from_sphere = cfs

        guard let dc = DiffuseCube(device: device)
        else {
            return nil
        }
        diffuse_cube = dc
        
        do {
            pipelineState = try EnvRenderer.buildRenderPipelineWithDevice(
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
            mesh = try EnvRenderer.buildMesh(
                device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }

        do {
            guard let hdr = try EnvRenderer.loadHdr(
                device: device)
            else {
                return nil
            }
            colorMap = hdr
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

        let vertexFunction = library?.makeFunction(name: "envVertexShader")
        let fragmentFunction = library?.makeFunction(name: "envFragmentShader")

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
            forResource: "cubes",
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
            throw EnvRendererError.badVertexDescriptor
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

    class func loadHdr(device: MTLDevice) throws -> MTLTexture? {
        guard let url = Bundle.main.url(
            forResource: "kloppenheim_06_4k",//"venetian_crossroads_2k",
            withExtension: "hdr")
        else {
            return nil
        }
        let options = [
            kCGImageSourceShouldAllowFloat : kCFBooleanTrue
        ]
        guard let image_source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary)
        else {
            return nil
        }
        guard let image = CGImageSourceCreateImageAtIndex(image_source, 0, nil)
        else {
            return nil
        }
        let textureLoader = MTKTextureLoader(device: device)

        let textureLoaderOptions = [
            MTKTextureLoader.Option.textureUsage: NSNumber(
                value: MTLTextureUsage.shaderRead.rawValue),
            MTKTextureLoader.Option.textureStorageMode: NSNumber(
                value: MTLStorageMode.`private`.rawValue),
        ]
        return try textureLoader.newTexture(cgImage: image, options: textureLoaderOptions)
    }
    
    override func clear_color() -> MTLClearColor {
        return MTLClearColorMake(0.6, 0.6, 0.8, 1.0);
    }
  
    override func render_pass_descriptor(index: Int) -> MTLRenderPassDescriptor? {
        switch index {
        case 0:
            return cube_from_sphere.render_pass_descriptor()
        case 1:
            return diffuse_cube.render_pass_descriptor()
        default:
            return nil
        }
    }
   
    override func draw_pass(renderEncoder: MTLRenderCommandEncoder, index: Int) {
        switch index {
        case 0:
            cube_from_sphere.draw_pass(renderEncoder: renderEncoder,
                                       sphereTexture: colorMap)
        case 1:
            diffuse_cube.draw_pass(renderEncoder: renderEncoder,
                                      hdriTexture: cube_from_sphere.texture!)
        default:
            return
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

        renderEncoder.setFragmentTexture(
            cube_from_sphere.texture, index: TextureIndex.color.rawValue)

        renderEncoder.setFragmentTexture(
            diffuse_cube.texture, index: TextureIndex.diffuse.rawValue)
        
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

