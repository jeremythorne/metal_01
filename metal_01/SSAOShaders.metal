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


vertex ColorInOut SSAOVertexGBuffer(Vertex in [[stage_in]],
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


fragment float4 SSAOFragmentGBuffer(ColorInOut in [[stage_in]])
{
    //return in.normal.xy;
    return float4(in.normal.xy, in.viewpos.z, 1);
}

struct ScreenSpace {
    float4 position [[position]];
    float2 viewpos;
    float4 screenpos;
};


vertex ScreenSpace SSAOVertexShader(uint vertex_id [[vertex_id]],
                                    constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]])
{
    float2 pos[] = {{-1, -1}, {1, 1}, {-1, 1},
        {-1, -1}, {1, -1}, {1, 1}
    };
    ScreenSpace out;
    out.position = float4(pos[vertex_id], 0, 1);
    // invert the projection to reconstruct the view position
    out.viewpos = out.position.xy / float2(uniforms.projectionMatrix[0][0], uniforms.projectionMatrix[1][1]);
    out.screenpos = out.position;
    return out;
}

fragment float4 SSAOFragmentShader(ScreenSpace in [[stage_in]],
                                    depth2d<float> depthMap     [[ texture(TextureIndexDepthMap) ]],
                                   texture2d<float> normalMap     [[ texture(TextureIndexNormalMap) ]],
                                   constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                   constant float3* noise [[ buffer(BufferIndexNoise )]],
                                   constant float3* samples [[ buffer(BufferIndexSSAOSamples )]]
                                   ) {

    constexpr float radius    = 0.6;
    constexpr float bias      = 0.005;
    constexpr float magnitude = 1.1;
    constexpr float contrast  = 1.1;
    
    constexpr sampler normalSampler;

    // reconstruct the view position and normal
    // normal map:
    // rg = xy of viewspace normal
    // b = depth
    float2 uv = (in.screenpos.xy / in.screenpos.w + 1) / 2;
    uv.y = 1 - uv.y;
    float3 normalSample = normalMap.sample(normalSampler, uv).rgb;
    float3 normal = normalize(float3(normalSample.rg, sqrt(1 - length_squared(normalSample.rg))));
    float depth = normalSample.b;
    float3 viewpos(in.viewpos.xy * depth, depth);
    
    // fetch a random unit vector from our noise buffer
    int noiseS = int(sqrt(float(NUM_NOISE_SAMPLES)));
    int noiseX = int(uv.x * uniforms.screenSize.x - 0.5) % noiseS;
    int noiseY = int(uv.y * uniforms.screenSize.y - 0.5) % noiseS;
    float3 random = noise[noiseX + noiseY * noiseS];

    // offset the normal by the random vector and construct a orthonormal basis
    float3 tangent  = normalize(random - normal * dot(random, normal));
    float3 binormal = cross(normal, tangent);
    matrix_float3x3 tbn  = matrix_float3x3(tangent, binormal, normal);

    float occlusion = NUM_SSAO_SAMPLES;

    for (unsigned int i = 0; i < NUM_SSAO_SAMPLES; ++i) {
        // offset the view position by a sample transformed by the noisy normal
        float3 samplePosition = viewpos.xyz + (tbn * samples[i]) * radius;
        
        // project that position back to screen space
        float4 sampleNDC = uniforms.projectionMatrix * float4(samplePosition, 1.0);
        sampleNDC.xyz /= sampleNDC.w;
        float2 sampleUV = sampleNDC.xy * 0.5 + 0.5;
        sampleUV.y = 1 - sampleUV.y;
        
        // fetch the depth at the new screen space coord and compare to our sample
        float sampleDepth = normalMap.sample(normalSampler, sampleUV.xy).b;
        float occluded = select(0, 1, samplePosition.z + bias <= sampleDepth);
        occluded *= smoothstep(0, 1, radius / abs(samplePosition.z - sampleDepth));
        // accumulate the occlusion
        occlusion -= occluded;
    }
    occlusion /= NUM_SSAO_SAMPLES;
    occlusion  = pow(occlusion, magnitude);
    occlusion  = contrast * (occlusion - 0.5) + 0.5;
    return float4(float3(occlusion), 1.0);
}

vertex ScreenSpace BlurVertexShader(uint vertex_id [[vertex_id]])
{
    float2 pos[] = {{-1, -1}, {1, 1}, {-1, 1},
        {-1, -1}, {1, -1}, {1, 1}
    };

    ScreenSpace out;
    out.position = float4(pos[vertex_id], 0, 1);
    out.screenpos = out.position;

    return out;
}

#define MAX_SIZE        5
#define MAX_KERNEL_SIZE ((MAX_SIZE * 2 + 1) * (MAX_SIZE * 2 + 1))

void findMean(int i0, int i1, int j0, int j1, float2 uv, float2 screenScale,
              texture2d<float> map     [[ texture(TextureIndexColor) ]],
              thread float3& mean, thread float& minVariance) {
    constexpr sampler sampler;
    constexpr float3 valueRatios = float3(0.3, 0.59, 0.11);
    float values[MAX_KERNEL_SIZE] = {0};
    
    float3 sum = float3(0);
    int count = 0;
    for (int j = j0; j <= j1; j++) {
        for(int i = i0; i <= i1; i++) {
            float3 sample = map.sample(sampler, uv + float2(i, j) * screenScale).rgb;
            sum += sample;
            count += 1;
            values[count] = dot(valueRatios, sample);
        }
    }
    float3 meanTemp = sum / count;
    float valueMean = dot(valueRatios, meanTemp);
    float variance = 0;
    for (int i = 0; i < count; ++i) {
      variance += pow(values[i] - valueMean, 2);
    }

    variance /= count;
    
    if (variance < minVariance || minVariance <= -1) {
      mean = meanTemp;
      minVariance = variance;
    }
}

// Kuwahara filter
fragment float4 BlurFragmentShader(ScreenSpace in [[stage_in]],
                                   constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                                   texture2d<float> map     [[ texture(TextureIndexColor) ]]) {

    constexpr float size = 3;
    float2 uv = (in.screenpos.xy / in.screenpos.w + 1) / 2;
    uv.y = 1 - uv.y;
    float2 scale = 1 / uniforms.screenSize;
    float3 mean = float3(0);
    float minVariance = -1;
    // pick the mean of the sub window with the lowest variance
    // Lower Left
    findMean(-size, 0, -size, 0, uv, scale, map, mean, minVariance);
    // Upper Right
    findMean(0, size, 0, size, uv, scale, map, mean, minVariance);
    // Upper Left
    findMean(-size, 0, 0, size, uv, scale, map, mean, minVariance);
    // Lower Right
    findMean(0, size, -size, 0, uv, scale, map, mean, minVariance);

    
    return float4(mean, 1);
}
