//
//  ShaderTypes.h
//  metal_01
//
//  Created by Jeremy Thorne on 20/12/2024.
//

//
//  Header containing types and enum constants shared between Metal shaders and Swift/ObjC source
//
#ifndef ShaderTypes_h
#define ShaderTypes_h

#ifdef __METAL_VERSION__
#define NS_ENUM(_type, _name) enum _name : _type _name; enum _name : _type
typedef metal::int32_t EnumBackingType;
#else
#import <Foundation/Foundation.h>
typedef NSInteger EnumBackingType;
#endif

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#define CONSTANT constant const constexpr
#else
#define CONSTANT static const
#endif

CONSTANT unsigned int NUM_QUADS_PER_SHAPE = 4;
CONSTANT unsigned int NUM_VERTS_PER_QUAD = 6;
CONSTANT unsigned int NUM_PRIMS_PER_SHAPE = NUM_QUADS_PER_SHAPE * 2;
CONSTANT unsigned int NUM_SHAPES_X                    = 64;
CONSTANT unsigned int NUM_SHAPES_Y                    = 64;
CONSTANT unsigned int NUM_SHAPES                      = (NUM_SHAPES_X * NUM_SHAPES_Y);
CONSTANT unsigned int NUM_VERTICES_PER_SHAPE              = NUM_VERTS_PER_QUAD * NUM_QUADS_PER_SHAPE;

CONSTANT unsigned int OBJECT_THREADS_PER_THREADGROUP      = 1;

CONSTANT unsigned int MESH_THREADS_PER_THREADGROUP_POW2   = 3;
CONSTANT unsigned int MESH_THREADS_PER_THREADGROUP        = (1 << MESH_THREADS_PER_THREADGROUP_POW2);
CONSTANT unsigned int MESH_THREADS_PER_THREADGROUP_MASK   = (MESH_THREADS_PER_THREADGROUP - 1);
CONSTANT unsigned int FIRST_TP_OF_LAST_THREADGROUP        = (MESH_THREADS_PER_THREADGROUP * (NUM_SHAPES / MESH_THREADS_PER_THREADGROUP));
CONSTANT unsigned int NUM_PRIMITIVES_OF_LAST_THREADGROUP  = (NUM_SHAPES - FIRST_TP_OF_LAST_THREADGROUP) * NUM_PRIMS_PER_SHAPE;
CONSTANT unsigned int MAX_VERTICES_PER_THREADGROUP        = NUM_VERTICES_PER_SHAPE * MESH_THREADS_PER_THREADGROUP;
CONSTANT unsigned int MAX_PRIMITIVES_PER_THREADGROUP      = MESH_THREADS_PER_THREADGROUP * NUM_PRIMS_PER_SHAPE;

CONSTANT unsigned int THREADGROUPS_PER_MESHGRID           = (NUM_SHAPES + MESH_THREADS_PER_THREADGROUP_MASK) / MESH_THREADS_PER_THREADGROUP;

CONSTANT unsigned int NUM_NOISE_SAMPLES = 16;
CONSTANT unsigned int NUM_SSAO_SAMPLES = 8;


typedef NS_ENUM(EnumBackingType, BufferIndex)
{
    BufferIndexMeshPositions = 0,
    BufferIndexMeshGenerics  = 1,
    BufferIndexUniforms      = 2,
    BufferIndexMeshBytes     = 3,
    BufferIndexShadowLight   = 4,
    BufferIndexNoise         = 5,
    BufferIndexSSAOSamples   = 6,
    BufferIndexCubeFromSphere = 7,
};

typedef NS_ENUM(EnumBackingType, VertexAttribute)
{
    VertexAttributePosition  = 0,
    VertexAttributeTexcoord  = 1,
    VertexAttributeNormal  = 2,
};

typedef NS_ENUM(EnumBackingType, TextureIndex)
{
    TextureIndexColor     = 0,
    TextureIndexShadowMap = 1,
    TextureIndexDepthMap = 2,
    TextureIndexNormalMap = 3,
    TextureIndexDiffuse = 4,
};

typedef struct
{
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 modelMatrix;
    matrix_float4x4 viewMatrix;
    matrix_float4x4 modelViewMatrix;
    float time;
    vector_float2 screenSize;
} Uniforms;

typedef struct {
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
    vector_float3 direction;
} ShadowLightUniform;

typedef struct {
    matrix_float4x4 projectionMatrix;
    matrix_float4x4 viewMatrix;
} CubeFromSphereUniform;

#endif /* ShaderTypes_h */

