//
//  GrassShaders.metal
//  metal_01
//
//  Created by Jeremy Thorne on 23/12/2024.
//
// initial code borrowed from https://github.com/peterwmwong/x-mesh-shader/tree/main/x-mesh-shader


#include "ShaderTypes.h"
#include <metal_stdlib>
using namespace metal;

[[object]]
void grass_object_shader(mesh_grid_properties mgp) {
    mgp.set_threadgroups_per_grid(uint3(THREADGROUPS_PER_MESHGRID, 1, 1));
}

struct xorshift32_state {
    uint32_t a;
};

/* The state must be initialized to non-zero */
uint32_t xorshift32(thread xorshift32_state &state)
{
    /* Algorithm "xor" from p. 4 of Marsaglia, "Xorshift RNGs" */
    uint32_t x = state.a;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return state.a = x;
}

struct Blade {
    float3 origin;
    float3 colour;
    float3 initial_velocity;
    float orientation;
    float density;
};

struct VertexData {
    float4 position [[position]];
    float3 normal;
};

struct PrimitiveData {
    float3 color;
};

using Mesh = metal::mesh<
    VertexData,                     // Vertex Type
    PrimitiveData,                  // Primitive Type
    MAX_VERTICES_PER_THREADGROUP,   // Max Vertices
    MAX_PRIMITIVES_PER_THREADGROUP, // Max Primitives
    metal::topology::triangle
>;

float rand_float(thread xorshift32_state &seed, float max) {
    return xorshift32(seed) * max / __UINT32_MAX__;
}

float3 rand_vec(thread xorshift32_state &seed, float max) {
    float h = max / 2;
    return float3(rand_float(seed, max) - h, rand_float(seed, max) - h, rand_float(seed, max) - h);
}

Blade create_blade(uint tid, float3 origin) {
    xorshift32_state seed = {tid};
    rand_float(seed, 1.0);
    return Blade{
        .origin =  origin + rand_vec(seed, 0.1),
        .colour = float3(0.2f + rand_float(seed, 0.2f), 1.0f, 1.0f),
        .orientation = rand_float(seed, 3.14159),
        .initial_velocity = float3(0.0f, 0.2f, 0.0f) + rand_vec(seed, 0.2f),
        .density = 0.5f + rand_float(seed, 1.0f)
    };
}


float3 transform_normal(float4x4 m, float3 v) {
    float3x3 m3(m[0].xyz, m[1].xyz, m[2].xyz);
    return m3 * v;
}

void add_quad(thread VertexData *vertices, thread int &index, float4x4 m0, float2 scale,
        float2 tex_off, float2 tex_scale, float density) {
    // quad facing z axis
    float3 scale3 = (float3) {scale.x, scale.y, 1.0f};
    float3 va = scale3 * (float3){-0.5f, 0.0f, 0.0f};
    float3 vb = scale3 * (float3){ 0.5f, 0.0f, 0.0f};
    float3 vc = scale3 * (float3){-0.5f, 1.0f, 0.0f};
    float3 vd = scale3 * (float3){ 0.5f, 1.0f, 0.0f};
    float3 normal = transform_normal(m0, (float3){ 0.0f, 0.0f, 1.0f});

    // float2 ta = tex_off + ((float2){0.0f, 0.0f} * tex_scale);
    // float2 tb = tex_off + ((float2){1.0f, 0.0f} * tex_scale);
    // float2 tc = tex_off + ((float2){0.0f, 1.0f} * tex_scale);
    // float2 td = tex_off + ((float2){1.0f, 1.0f} * tex_scale);
 
    //vertex_t v0 =  (vertex_t) {transform(m0, va), normal, colour, ta, density};
    //vertex_t v1 =  (vertex_t) {transform(m0, vb), normal, colour, tb, density};
    //vertex_t v2 =  (vertex_t) {transform(m0, vc), normal, colour, tc, density};
    //vertex_t v3 =  (vertex_t) {transform(m0, vd), normal, colour, td, density};

    VertexData v0 = {m0 * float4(va, 1.0), normal};
    VertexData v1 = {m0 * float4(vb, 1.0), normal};
    VertexData v2 = {m0 * float4(vc, 1.0), normal};
    VertexData v3 = {m0 * float4(vd, 1.0), normal};
    
    VertexData triangles[] = {
        v0, v1, v2,
        v2, v1, v3,
    };

    for (int i = 0; i < 6; i++) {
        vertices[index ++] = triangles[i];
    }
}


void axes_from_dir_up(float3 dir, float3 up,
                      thread float3 *x, thread float3 *y, thread float3 *z) {
    *y = normalize(dir);
    *x = cross(*y, normalize(up));
    *z = cross(*x, *y);
}

float3x3 rotationMatrix(float3 axis, float angle)
{
    axis = normalize(axis);
    float s = sin(angle);
    float c = cos(angle);
    float oc = 1.0 - c;
    
    return float3x3(oc * axis.x * axis.x + c,       oc * axis.x * axis.y - axis.z * s,  oc * axis.z * axis.x + axis.y * s,
                oc * axis.x * axis.y + axis.z * s,  oc * axis.y * axis.y + c,           oc * axis.y * axis.z - axis.x * s,
                oc * axis.z * axis.x - axis.y * s,  oc * axis.y * axis.z + axis.x * s,  oc * axis.z * axis.z + c);
}

void add_quads(const Blade blade, thread VertexData *vertices) {
    float3 x, y, z;
    float3 velocity = blade.initial_velocity;
    float3 origin = blade.origin;
    int N = NUM_QUADS_PER_SHAPE;
    float Nf = (float)N;
    int index = 0;
    for(int i = 0; i < N; i++) {
        float3 direction = rotationMatrix(float3(0.0f, 1.0f, 0.0f), blade.orientation) * float3(0.0f, 0.0f, 1.0f);
            
        axes_from_dir_up(velocity, direction, &x, &y, &z);
        float4x4 m0(float4(x, 0.0), float4(y, 0.0), float4(z, 0.0), float4(origin, 1.0));
        //float4x4 m0(1.0);
        //m0[3] = float4(origin, 1.0);
        float len = length(velocity);
        float2 tex_off = (float2){0.0f, i/Nf};
        float2 tex_scale = (float2){1.0f, 1.0f/Nf};
        float2 scale = {0.02, len};
        add_quad(vertices, index, m0, scale,
            tex_off, tex_scale, blade.density);
        origin = origin + velocity;
        velocity = velocity + (float3){0.0f, -0.008f, 0.0f};
    }
}

[[mesh]]
void grass_mesh_shader(Mesh m,
               uint tp_in_grid [[thread_position_in_grid]],
                       //uint tid_in_group [[thread_position_in_threadgroup]],
                constant Uniforms & uniforms [[ buffer(BufferIndexUniforms) ]],
                       constant float2 & offset [[ buffer(BufferIndexMeshBytes)]]) {
    const uint tid_in_group = tp_in_grid & MESH_THREADS_PER_THREADGROUP_MASK;
    if (tid_in_group == 0) {
        // Set once per Thread Group
        m.set_primitive_count(select(NUM_PRIMITIVES_OF_LAST_THREADGROUP, MESH_THREADS_PER_THREADGROUP * NUM_PRIMS_PER_SHAPE, tp_in_grid < FIRST_TP_OF_LAST_THREADGROUP));
    }
    if (tp_in_grid < NUM_SHAPES) {
        const float2 grid_pos  = float2(float(tp_in_grid % NUM_SHAPES_X), float(tp_in_grid / NUM_SHAPES_X));
        const float2 translate = 16 * (grid_pos / float2(float2(NUM_SHAPES_X, NUM_SHAPES_Y) - 1) - 0.5) + offset;
        
        uchar i = uchar(tid_in_group * NUM_VERTICES_PER_SHAPE);
        uchar p = uchar(tid_in_group * NUM_PRIMS_PER_SHAPE);

        Blade blade = create_blade(tp_in_grid, float3(translate.x, 0.0, translate.y));
        VertexData vertices[NUM_VERTICES_PER_SHAPE];
        add_quads(blade, vertices);
        for (unsigned int j = 0; j < NUM_VERTICES_PER_SHAPE; j++) {
            vertices[j].position = uniforms.projectionMatrix * uniforms.modelViewMatrix * vertices[j].position;
            m.set_vertex(i, vertices[j]);
            if (j % 3 == 0) {
                // Set once per Primitive
                m.set_primitive(p + (j / 3), { .color = blade.colour });
            }
            m.set_index(i, i);
            i++;
        }
    }
}

struct FragmentIn {
    PrimitiveData primitive;
    VertexData v;
};

[[fragment]]
half4 grass_fragment_shader(FragmentIn in [[stage_in]]) {
    
    float3 light_dir = {0.5, -0.5, 0.0};
    float3 light_colour = {0.9, 0.9, 0.7};
    float3 ambient_colour = {0.2, 0.2, 0.2};
    float lambert = saturate(dot(light_dir, in.v.normal));
    float3 frag_color = in.primitive.color * lambert * light_colour + ambient_colour;
    
    return half4(half3(frag_color), 1);
}
