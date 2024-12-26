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

enum OceanRendererError: Error {
    case badVertexDescriptor
}

class OceanRenderer {

    public let device: MTLDevice
    var pipelineState: MTLRenderPipelineState
    var colorMap: MTLTexture

    var mesh: MTKMesh

    @MainActor
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!

        let mtlVertexDescriptor = OceanRenderer.buildMetalVertexDescriptor()

        do {
            pipelineState = try OceanRenderer.buildRenderPipelineWithDevice(
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
            mesh = try OceanRenderer.buildMesh(
                device: device, mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to build MetalKit Mesh. Error info: \(error)")
            return nil
        }

        do {
            colorMap = try OceanRenderer.loadTexture(
                device: device, textureName: "ColorMap")
        } catch {
            print("Unable to load texture. Error info: \(error)")
            return nil
        }
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
            throw OceanRendererError.badVertexDescriptor
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

    func clearColor() -> MTLClearColor {
        return MTLClearColorMake(0.6, 0.6, 0.8, 1.0);
    }
    
    func draw(in view: MTKView, renderEncoder: MTLRenderCommandEncoder) {
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

