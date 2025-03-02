//
//  Shaders.metal
//  metal_01
//
//  Created by Jeremy Thorne on 20/12/2024.
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <metal_math>
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

struct ScreenSpace {
    float4 position [[position]];
    float2 viewpos;
    float4 screenpos;
};

vertex ScreenSpace cubeFromSphereVertexShader(uint vertex_id [[vertex_id]])
{
    float2 pos[] = {{-1, -1}, {1, 1}, {-1, 1},
        {-1, -1}, {1, -1}, {1, 1}
    };

    ScreenSpace out;
    out.position = float4(pos[vertex_id], 0, 1);
    out.screenpos = out.position;

    return out;
}

float2 theta_phi_from_normal(float3 normal)
{
    float3 n = normalize(normal);
    float phi = 0.5 - atan2(n.y, length(n.xz)) / (M_PI_F);
    float theta = 0.5 + atan2(n.z, n.x) / (2 * M_PI_F);
    return float2(theta, phi);
}

// this shader writes to 6 textures, one for each face of the cube
struct CubeOut {
    float4 color_px [[color(0)]];
    float4 color_mx [[color(1)]];
    float4 color_py [[color(2)]];
    float4 color_my [[color(3)]];
    float4 color_pz [[color(4)]];
    float4 color_mz [[color(5)]];
};

fragment CubeOut cubeFromSphereFragmentShader(ScreenSpace in [[stage_in]],
                                                texture2d<float> colorMap [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                      mag_filter::linear,
                                        min_filter::linear,
                                        address::repeat);
    
    // index orientation
    // 0 +X
    // 1 -X
    // 2 +Y
    // 3 -Y
    // 4 +Z
    // 5 -Z
    
    float2 uvpx = theta_phi_from_normal(float3(1.0, in.screenpos.y, -in.screenpos.x));
    float2 uvmx = theta_phi_from_normal(float3(-1.0, in.screenpos.y, in.screenpos.x));
    float2 uvpy = theta_phi_from_normal(float3(in.screenpos.x, 1.0, -in.screenpos.y));
    float2 uvmy = theta_phi_from_normal(float3(in.screenpos.x, -1.0, in.screenpos.y));
    float2 uvpz = theta_phi_from_normal(float3(in.screenpos.x, in.screenpos.y, 1.0));
    float2 uvmz = theta_phi_from_normal(float3(-in.screenpos.x, in.screenpos.y, -1.0));
    CubeOut out;
    out.color_px = colorMap.sample(colorSampler, uvpx);
    out.color_mx = colorMap.sample(colorSampler, uvmx);
    out.color_py = colorMap.sample(colorSampler, uvpy);
    out.color_my = colorMap.sample(colorSampler, uvmy);
    out.color_pz = colorMap.sample(colorSampler, uvpz);
    out.color_mz = colorMap.sample(colorSampler, uvmz);
    return out;
}

#define PI 3.14159265359

vertex ScreenSpace diffuseCubeVertexShader(uint vertex_id [[vertex_id]])
{
    float2 pos[] = {{-1, -1}, {1, 1}, {-1, 1},
        {-1, -1}, {1, -1}, {1, 1}
    };

    ScreenSpace out;
    out.position = float4(pos[vertex_id], 0, 1);
    out.screenpos = out.position;

    return out;
}

fragment CubeOut diffuseCubeFragmentShader(ScreenSpace in [[stage_in]],
                                                texturecube<float> colorMap [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                      mag_filter::linear,
                                        min_filter::linear,
                                        address::repeat);
    
    // index orientation
    // 0 +X
    // 1 -X
    // 2 +Y
    // 3 -Y
    // 4 +Z
    // 5 -Z
    float3 normal[6];
    float3 irradiance[6];
    
    normal[0] = normalize(float3(1.0, in.screenpos.y, -in.screenpos.x));
    normal[1] = normalize(float3(-1.0, in.screenpos.yx));
    normal[2] = normalize(float3(in.screenpos.x, 1.0, -in.screenpos.y));
    normal[3] = normalize(float3(in.screenpos.x, -1.0, in.screenpos.y));
    normal[4] = normalize(float3(in.screenpos.x, in.screenpos.y, 1.0));
    normal[5] = normalize(float3(-in.screenpos.x, in.screenpos.y, -1.0));

    // from https://learnopengl.com/PBR/IBL/Diffuse-irradiance
    for(int i = 0; i < 6; i++)
    {
        irradiance[i] = float3(0.0);
        
        float3 up    = float3(0.0, 1.0, 0.0);
        float3 right = normalize(cross(up, normal[i]));
        up         = normalize(cross(normal[i], right));
        
        float sampleDelta = 0.25;
        float nrSamples = 0.0;
        for(float phi = 0.0; phi < 2.0 * PI; phi += sampleDelta)
        {
            for(float theta = 0.0; theta < 0.5 * PI; theta += sampleDelta)
            {
                // spherical to cartesian (in tangent space)
                float3 tangentSample =float3(sin(theta) * cos(phi),  sin(theta) * sin(phi), cos(theta));
                // tangent space to world
                float3 sampleVec = tangentSample.x * right + tangentSample.y * up + tangentSample.z * normal[i];
                
                irradiance[i] += colorMap.sample(colorSampler, sampleVec).rgb * cos(theta) * sin(theta);
                nrSamples++;
            }
        }
        irradiance[i] = PI * irradiance[i] * (1.0 / float(nrSamples));
        
    }
    CubeOut out;
    out.color_px = float4(irradiance[0], 1.0);
    out.color_mx = float4(irradiance[1], 1.0);
    out.color_py = float4(irradiance[2], 1.0);
    out.color_my = float4(irradiance[3], 1.0);
    out.color_pz = float4(irradiance[4], 1.0);
    out.color_mz = float4(irradiance[5], 1.0);
    return out;
}


vertex ColorInOut envVertexShader(Vertex in [[stage_in]],
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

fragment float4 envFragmentShader(ColorInOut in [[stage_in]],
                               constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                    constant ShadowLightUniform & shadow_light [[ buffer(BufferIndexShadowLight)]],
                                    depth2d<float> shadowMap     [[ texture(TextureIndexShadowMap) ]],
                                  texturecube<float> colorMap     [[ texture(TextureIndexColor) ]],
                                  texturecube<float> diffuseMap     [[ texture(TextureIndexDiffuse) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear,
                                   address::repeat);
    
    float3 V = normalize(float(0) - in.viewpos.xyz / in.viewpos.w);
    float3 N = normalize(in.normal);
    float3 reflection = reflect(-V, N);
    float4 colorSample = colorMap.sample(colorSampler, reflection);
    float4 diffuse = diffuseMap.sample(colorSampler, N);

    float specularity = fmod(in.texCoord.y, 0.1) < 0.05 ? 1.0 : 0.0;
    
    return float4(mix(diffuse.rgb, colorSample.rgb, specularity), 1);
    //return float4(shadow_light.projectionMatrix * shadow_light.viewMatrix * in.worldpos);
    //return float4(in.worldpos.xyz, 1.0);
}
