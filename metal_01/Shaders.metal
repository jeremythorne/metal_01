//
//  Shaders.metal
//  metal_01
//
//  Created by Jeremy Thorne on 20/12/2024.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float4 viewpos;
    float2 texCoord;
} ColorInOut;

float compound_sin(float x, float t, float3 scale_x, float3 scale_t) {
    return sin(x * scale_x.x + t * scale_t.x) +
        sin(x * scale_x.y + t * scale_t.y) +
    sin(x * scale_x.z + t * scale_t.z) / 3.0;
}

float4 waves(float4 position, float time) {
    position.y += 0.5 * compound_sin(position.x, time, float3(0.1, 0.23, 0.33), float3(1.0, 1.5, 0.4));
    position.y += 0.5 * compound_sin(position.z, time, float3(0.02, 0.18, 0.28), float3(1.8, 1.8, 0.8));
    return position;
}

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    float4 position = float4(in.position, 1.0);
    position = waves(position, uniforms.time);
    float4 centre = waves(float4(0.0), uniforms.time);
    position.y -= centre.y;
    out.viewpos = uniforms.modelViewMatrix * position;
    out.position = uniforms.projectionMatrix * out.viewpos;
    out.texCoord = in.texCoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::repeat);

    float2 uv = in.texCoord.xy * 10;
    uv.y += 0.01 * compound_sin(uv.x, uniforms.time, float3(3.5, 4.8, 7.3), float3(0.35, 1.05, 0.45));
    uv.x += 0.12 * compound_sin(uv.y, uniforms.time, float3(4.0, 6.8, 11.3), float3(0.5, 0.75, 0.2));
    uv.y += 0.12 * compound_sin(uv.x, uniforms.time, float3(4.2, 6.3, 8.2), float3(0.64, 1.65, 0.45));
    half4 colorSample   = colorMap.sample(colorSampler, uv);

    float fog = 1.0 - exp(in.viewpos.z / 20);
    float4 fog_color = float4(0.6, 0.6, 0.8, 1.0);
    return mix(float4(colorSample), fog_color, fog);
}
