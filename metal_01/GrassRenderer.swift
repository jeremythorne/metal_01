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

enum GrassRendererError: Error {
    case badVertexDescriptor
}

class GrassRenderer {

    public let device: MTLDevice
    var pipelineState: MTLRenderPipelineState
    var colorMap: MTLTexture

    @MainActor
    init?(metalKitView: MTKView) {
        self.device = metalKitView.device!

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

        do {
            colorMap = try GrassRenderer.loadTexture(
                device: device, textureName: "Leaf")
        } catch {
            print("Unable to load texture. Error info: \(error)")
            return nil
        }
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

    func clearColor() -> MTLClearColor {
        return MTLClearColorMake(0.0, 0.1, 0.0, 1.0);
    }
    
    func draw(in view: MTKView, renderEncoder: MTLRenderCommandEncoder) {
        /// Per frame updates hare
                
        renderEncoder.setRenderPipelineState(pipelineState)

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
    }
}

