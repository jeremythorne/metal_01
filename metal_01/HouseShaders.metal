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
    float3 normal [[attribute(VertexAttributeNormal)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float3 normal;
    float4 worldpos;
    float4 viewpos;
    float2 texCoord;
} ColorInOut;

static float3 transform_normal(float4x4 m, float3 v) {
    float3x3 m3(m[0].xyz, m[1].xyz, m[2].xyz);
    return m3 * v;
}

vertex float4 houseVertexShadow(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                constant ShadowLightUniform & shadow_light [[ buffer(BufferIndexShadowLight)]])
{
    float4 position = float4(in.position, 1.0);
    return shadow_light.projectionMatrix * shadow_light.viewMatrix * uniforms.modelMatrix * position;
}

vertex ColorInOut houseVertexShader(Vertex in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    float4 position = float4(in.position, 1.0);
    out.normal = transform_normal(uniforms.modelViewMatrix, in.normal);
    out.worldpos = uniforms.modelMatrix * position;
    out.viewpos = uniforms.viewMatrix * out.worldpos;
    out.position = uniforms.projectionMatrix * out.viewpos;
    out.texCoord = in.texCoord;

    return out;
}

static float shadow(float3 worldPosition,
                    depth2d<float, access::sample> depthMap,
                    float4x4 viewProjectionMatrix)
{
    float4 shadowNDC = (viewProjectionMatrix * float4(worldPosition, 1));
    shadowNDC.xyz /= shadowNDC.w;
    float2 shadowCoords = shadowNDC.xy * 0.5 + 0.5;
    shadowCoords.y = 1 - shadowCoords.y;

    constexpr sampler shadowSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear,
        compare_func::greater_equal);

    constexpr float bias = 0.02;
    
    float shadowCoverage = depthMap.sample_compare(shadowSampler, shadowCoords, shadowNDC.z -bias);
    return shadowCoverage;
}

fragment float4 houseFragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                    constant ShadowLightUniform & shadow_light [[ buffer(BufferIndexShadowLight)]],
                                    depth2d<float> shadowMap     [[ texture(TextureIndexShadowMap) ]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::repeat);
    
    float2 uv = in.texCoord.xy;
    half4 colorSample   = colorMap.sample(colorSampler, uv);
    
    float3 light_dir = -shadow_light.direction;
    float3 light_colour = {1.9, 1.9, 1.7};
    float3 ambient_colour = float3(0.6, 0.6, 0.8) / 4;
    
    float3 V = normalize(float(0) - in.viewpos.xyz / in.viewpos.w);
    float3 N = in.normal;
    float3 L = normalize(light_dir);
    float3 H = normalize(L + V);
    float NdotL = dot(N, L);
    
    
    float lambert = saturate(NdotL);
    float3 color = float3(colorSample.xyz) * lambert * light_colour;
    
    float shadowFactor = 1 - shadow(in.worldpos.xyz, shadowMap, shadow_light.projectionMatrix * shadow_light.viewMatrix);
    
    color = shadowFactor * color + ambient_colour;
    
    return float4(color, 1);
    //return float4(shadow_light.projectionMatrix * shadow_light.viewMatrix * in.worldpos);
    //return float4(in.worldpos.xyz, 1.0);
}
