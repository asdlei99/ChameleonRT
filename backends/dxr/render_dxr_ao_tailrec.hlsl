#include "util.hlsl"
#include "lcg_rng.hlsl"

struct AORayPayload {
    int n_occluded;
};

// These images all need to be moved up to global params, same with the scene
// Raytracing output texture, accessed as a UAV
RWTexture2D<float4> output : register(u0);

// Accumulation buffer for progressive refinement
RWTexture2D<float4> accum_buffer : register(u1);

#ifdef REPORT_RAY_STATS
RWTexture2D<uint> ray_stats : register(u2);
#endif

// Raytracing acceleration structure, accessed as a SRV
RaytracingAccelerationStructure scene : register(t0);

// View params buffer
cbuffer ViewParams : register(b0) {
    float4 cam_pos;
    float4 cam_du;
    float4 cam_dv;
    float4 cam_dir_top_left;
}

struct RayPayloadPrimary {
    float dist;
};

// Also needs to become a global constant
cbuffer SceneParams : register(b1) {
    float ao_distance;
};

// Becomes Global constant
cbuffer FrameId : register(b2) {
    uint32_t frame_id;
}

[shader("raygeneration")] 
void RayGen_AO() {
    const uint2 pixel = DispatchRaysIndex().xy;
    const float2 dims = float2(DispatchRaysDimensions().xy);
    LCGRand rng = get_rng(frame_id);
    const float2 d = (pixel + float2(lcg_randomf(rng), lcg_randomf(rng))) / dims;

    RayDesc ray;
    ray.Origin = cam_pos.xyz;
    ray.Direction = normalize(d.x * cam_du.xyz + d.y * cam_dv.xyz + cam_dir_top_left.xyz);
    ray.TMin = 0;
    ray.TMax = 1e20f;

    uint ray_count = 0;
    RayPayloadPrimary payload;
    TraceRay(scene, RAY_FLAG_FORCE_OPAQUE, 0xff, PRIMARY_RAY, 1, PRIMARY_RAY, ray, payload);
}

[shader("miss")]
void Miss_AO(inout RayPayloadPrimary payload : SV_RayPayload) {
    const uint2 pixel = DispatchRaysIndex().xy;
    const float4 accum_color = (frame_id * accum_buffer[pixel]) / (frame_id + 1);
    accum_buffer[pixel] = accum_color;
    output[pixel] = float4(linear_to_srgb(accum_color.r),
            linear_to_srgb(accum_color.g),
            linear_to_srgb(accum_color.b), 1.f);

#ifdef REPORT_RAY_STATS
    ray_stats[pixel] = 1;
#endif
}

[shader("miss")]
void ShadowMiss_AO(inout AORayPayload occlusion : SV_RayPayload) {
    --occlusion.n_occluded;
}

// Per-mesh parameters for the closest hit
StructuredBuffer<float3> vertices : register(t0, space1);
StructuredBuffer<uint3> indices : register(t1, space1);
StructuredBuffer<float3> normals : register(t2, space1);
StructuredBuffer<float2> uvs : register(t3, space1);

cbuffer MeshData : register(b0, space1) {
    uint32_t num_normals;
    uint32_t num_uvs;
    uint32_t material_id;
}

[shader("closesthit")] 
void ClosestHit_AO(inout RayPayloadPrimary payload, Attributes attrib) {
    uint3 idx = indices[NonUniformResourceIndex(PrimitiveIndex())];

    float3 va = vertices[NonUniformResourceIndex(idx.x)];
    float3 vb = vertices[NonUniformResourceIndex(idx.y)];
    float3 vc = vertices[NonUniformResourceIndex(idx.z)];
    float3 ng = normalize(cross(vb - va, vc - va));

    float3x3 inv_transp = float3x3(WorldToObject4x3()[0], WorldToObject4x3()[1], WorldToObject4x3()[2]);
    float3 v_z = normalize(mul(inv_transp, ng));
    
    if (dot(v_z, WorldRayDirection()) > 0.0) {
        v_z = -v_z;
    }

    float3 v_x, v_y;
    ortho_basis(v_x, v_y, v_z);

    const uint2 pixel = DispatchRaysIndex().xy;
    LCGRand rng = get_rng(frame_id);
    // Advance the RNG 2 to not correlate with the primary ray samples
    lcg_randomf(rng);
    lcg_randomf(rng);

    // We don't run closest hit at all here so we actually use the miss shader to count
    //misses by decrementing the payload's occluded value
    AORayPayload ao_payload;
    ao_payload.n_occluded = NUM_SAMPLES;
    for (int i = 0; i < NUM_SAMPLES; ++i) {
        const float theta = sqrt(lcg_randomf(rng));
        const float phi = 2.f * M_PI * lcg_randomf(rng);

        const float x = cos(phi) * theta;
        const float y = sin(phi) * theta;
        const float z = sqrt(1.f - theta * theta);

        RayDesc ray;
        ray.Origin = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
        ray.TMin = EPSILON;
        ray.TMax = ao_distance;
        ray.Direction = normalize(x * v_x + y * v_y + z * v_z);

        const uint32_t occlusion_flags = RAY_FLAG_FORCE_OPAQUE
            | RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH
            | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

        TraceRay(scene, occlusion_flags, 0xff, PRIMARY_RAY, 1, OCCLUSION_RAY, ray, ao_payload);
    }
    float3 ao_color = 1.f - float(ao_payload.n_occluded) / NUM_SAMPLES;

    const float4 accum_color = (float4(ao_color, 1.0) + frame_id * accum_buffer[pixel]) / (frame_id + 1);
    accum_buffer[pixel] = accum_color;

    output[pixel] = float4(linear_to_srgb(accum_color.r),
            linear_to_srgb(accum_color.g),
            linear_to_srgb(accum_color.b), 1.f);

#ifdef REPORT_RAY_STATS
    ray_stats[pixel] = 1 + NUM_SAMPLES;
#endif
}

