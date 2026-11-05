//
//  Shaders.metal
//  Stray Scanner
//
//  Created by Kenneth Blomqvist on 11/28/20.
//  Copyright © 2020 Stray Robots. All rights reserved.
//

#include <metal_stdlib>
#import "ShaderTypes.h"

using namespace metal;

constant float MinDepth = 0.05;
constant float InvMaxDepth = 1.0 / 10.0;
constant float InvE3 = 1.0 / (M_E_F * M_E_F * M_E_F);

struct VertexIn {
    float2 vertexCoordinates [[attribute(0)]]; // Position index 0.
    float2 textureCoordinates [[attribute(1)]]; // Texture coordinate index 1.
};

struct VertexOut {
    float4 vertexCoordinate [[position]];
    float2 textureCoordinate;
};

struct ImageColorOut {
    float4 color;
    float2 textureCoordinate;
};

vertex VertexOut drawRectangle(const device VertexIn* vertexIn[[ buffer(0) ]],
    uint vertexIndex [[ vertex_id ]]) {
    VertexOut out;
    VertexIn v = vertexIn[vertexIndex];
    out.vertexCoordinate = float4(v.vertexCoordinates, 0.0, 1.0);
    out.textureCoordinate = v.textureCoordinates;
    return out;
}

/// Same quad, scaled so the 4:3 camera picture fills any screen shape (crops the sides, never stretches).
vertex VertexOut drawRectangleFill(const device VertexIn* vertexIn[[ buffer(0) ]],
                                   constant float2& scale [[ buffer(1) ]],
                                   uint vertexIndex [[ vertex_id ]]) {
    VertexOut out;
    VertexIn v = vertexIn[vertexIndex];
    out.vertexCoordinate = float4(v.vertexCoordinates * scale, 0.0, 1.0);
    out.textureCoordinate = v.textureCoordinates;
    return out;
}

fragment half4 displayTexture(VertexOut in [[stage_in]],
                            texture2d<float, access::sample> capturedImageTextureY [[ texture(kTextureIndexY) ]],
                            texture2d<float, access::sample> capturedImageTextureCbCr [[ texture(kTextureIndexCbCr) ]]) {

    constexpr sampler colorSampler(address::clamp_to_edge, filter::linear);

    half4 ycbcr = half4(half(capturedImageTextureY.sample(colorSampler, in.textureCoordinate).r),
                        half2(capturedImageTextureCbCr.sample(colorSampler, in.textureCoordinate).rg), 1.0);

    const half4x4 ycbcrToRGBTransform = half4x4(
        half4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        half4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        half4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        half4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
    );

    return ycbcrToRGBTransform * ycbcr;
}

fragment half4 depthFragment(VertexOut in [[stage_in]], depth2d<float, access::sample> depthFrame [[ texture(0) ]]) {
    constexpr sampler depthSampler(address::clamp_to_edge, filter::bicubic);
    float depth = depthFrame.sample(depthSampler, in.textureCoordinate);

    depth = max(depth - MinDepth, 0.0);
    depth = min(depth * InvMaxDepth, M_E_F - InvE3);
    half clamped = 0.1 + (1.0 - (log(InvE3 + depth) + 3.0) / 4.0) * 0.8;
    return half4(clamped, clamped, clamped, 1.0);
}

// MARK: - stray-scanner-sf: view modes and live point cloud

// Google's Turbo colormap, polynomial approximation. x in [0, 1].
static float3 turbo(float x) {
    const float4 kRedVec4 = float4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const float4 kGreenVec4 = float4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const float4 kBlueVec4 = float4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const float2 kRedVec2 = float2(-152.94239396, 59.28637943);
    const float2 kGreenVec2 = float2(4.27729857, 2.82956604);
    const float2 kBlueVec2 = float2(-89.90310912, 27.34824973);
    x = saturate(x);
    float4 v4 = float4(1.0, x, x * x, x * x * x);
    float2 v2 = v4.zw * v4.z;
    return float3(dot(v4, kRedVec4) + dot(v2, kRedVec2),
                  dot(v4, kGreenVec4) + dot(v2, kGreenVec2),
                  dot(v4, kBlueVec4) + dot(v2, kBlueVec2));
}

constant float SFMaxDisplayDepth = 5.0;

static half3 ycbcrToRGB(texture2d<float, access::sample> textureY,
                        texture2d<float, access::sample> textureCbCr,
                        float2 uv) {
    constexpr sampler colorSampler(address::clamp_to_edge, filter::linear);
    float y = textureY.sample(colorSampler, uv).r;
    float2 cbcr = textureCbCr.sample(colorSampler, uv).rg - float2(0.5, 0.5);
    float3 rgb = float3(y + 1.402 * cbcr.y,
                        y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
                        y + 1.772 * cbcr.x);
    return half3(saturate(rgb));
}

// Depth in colour (near = blue, far = red); low-confidence LiDAR pixels are darkened.
fragment half4 depthColorFragment(VertexOut in [[stage_in]],
                                  texture2d<float, access::sample> depthTexture [[ texture(2) ]],
                                  texture2d<float, access::sample> confidenceTexture [[ texture(3) ]]) {
    constexpr sampler nearestSampler(address::clamp_to_edge, filter::nearest);
    float depth = depthTexture.sample(nearestSampler, in.textureCoordinate).r;
    float confidence = confidenceTexture.sample(nearestSampler, in.textureCoordinate).r * 255.0;
    half3 color = half3(turbo(depth / SFMaxDisplayDepth));
    if (confidence < 1.5) {
        color *= 0.35h;
    }
    return half4(color, 1.0h);
}

// Camera image with the depth colours blended on top.
fragment half4 overlayFragment(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> textureY [[ texture(0) ]],
                               texture2d<float, access::sample> textureCbCr [[ texture(1) ]],
                               texture2d<float, access::sample> depthTexture [[ texture(2) ]],
                               texture2d<float, access::sample> confidenceTexture [[ texture(3) ]]) {
    constexpr sampler nearestSampler(address::clamp_to_edge, filter::nearest);
    half3 rgb = ycbcrToRGB(textureY, textureCbCr, in.textureCoordinate);
    float depth = depthTexture.sample(nearestSampler, in.textureCoordinate).r;
    float confidence = confidenceTexture.sample(nearestSampler, in.textureCoordinate).r * 255.0;
    half3 depthColor = half3(turbo(depth / SFMaxDisplayDepth));
    half amount = confidence < 1.5 ? 0.15h : 0.45h;
    return half4(mix(rgb, depthColor, amount), 1.0h);
}

struct SFPointVertex {
    float4 position; // xyz world position, w = point size in metres
    float4 color;
};

struct SFPointUniforms {
    float4x4 viewProjection;
    float pointScale;   // pixels per metre at 1 m distance
    float clipY;        // points above this world height are hidden (ceiling cut)
    float maxPointSize; // pixels
    float pad0;
};

struct SFPointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex SFPointOut pointCloudVertex(const device SFPointVertex* points [[ buffer(0) ]],
                                   constant SFPointUniforms& uniforms [[ buffer(1) ]],
                                   uint vertexIndex [[ vertex_id ]]) {
    SFPointVertex p = points[vertexIndex];
    SFPointOut out;
    out.color = p.color;
    if (p.position.y > uniforms.clipY) {
        out.position = float4(2.0, 2.0, 2.0, 1.0); // outside the clip volume: culled
        out.pointSize = 1.0;
        return out;
    }
    float4 clip = uniforms.viewProjection * float4(p.position.xyz, 1.0);
    out.position = clip;
    float distance = max(clip.w, 0.05);
    out.pointSize = clamp(p.position.w * uniforms.pointScale / distance, 1.0, uniforms.maxPointSize);
    return out;
}

fragment half4 pointCloudFragment(SFPointOut in [[stage_in]],
                                  float2 pointCoord [[ point_coord ]]) {
    float2 d = pointCoord - float2(0.5, 0.5);
    if (dot(d, d) > 0.25) {
        discard_fragment();
    }
    return half4(in.color);
}

// MARK: - stray-scanner-sf: Gaussian splat viewer (own implementation, standard 3DGS EWA projection)

struct GSplat {
    packed_float3 position;
    half cov[6];        // xx, xy, xz, yy, yz, zz (world space)
    uchar4 color;       // rgb + opacity
    float covScale;     // covariance = cov × covScale (cov normalised per splat)
};

struct GSUniforms {
    float4x4 view;
    float4x4 projection;
    float2 viewport;    // pixels
    float2 focal;       // pixels
    float4 cameraPos;   // camera position in the splat file's coordinates
    uint hasSH;         // 1 = buffer(3) holds degree-1 SH (9 halves per splat)
    uint pad0, pad1, pad2;
};

struct GSOut {
    float4 position [[position]];
    float2 local;       // position inside the splat in standard deviations
    half4 color;
};

vertex GSOut gsVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device GSplat* splats [[ buffer(0) ]],
                      const device uint* order [[ buffer(1) ]],
                      constant GSUniforms& u [[ buffer(2) ]],
                      const device half* sh [[ buffer(3) ]]) {
    GSOut o;
    uint index = order[iid];
    GSplat s = splats[index];
    o.color = half4(s.color) / 255.0h;
    if (u.hasSH != 0u) {
        // View-dependent colour (degree 1): rgb += C1·(−y·c1 + z·c2 − x·c3), dir from camera to splat.
        float3 dir = normalize(float3(s.position) - u.cameraPos.xyz);
        const device half* c = sh + index * 9u;
        float3 c1 = float3(c[0], c[1], c[2]), c2 = float3(c[3], c[4], c[5]), c3 = float3(c[6], c[7], c[8]);
        float3 add = 0.48860251 * (-dir.y * c1 + dir.z * c2 - dir.x * c3);
        o.color.rgb = half3(saturate(float3(o.color.rgb) + add));
    }
    o.local = float2(0);
    float4 t = u.view * float4(float3(s.position), 1.0);
    float d = -t.z;                               // distance in front of the camera
    if (d < 0.02) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float4 clip = u.projection * t;
    if (abs(clip.x) > 1.3 * clip.w || abs(clip.y) > 1.3 * clip.w) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }

    float3x3 W = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3x3 S = float3x3(float3(s.cov[0], s.cov[1], s.cov[2]),
                          float3(s.cov[1], s.cov[3], s.cov[4]),
                          float3(s.cov[2], s.cov[4], s.cov[5])) * s.covScale;
    float3x3 C = W * S * transpose(W);
    // Jacobian of the perspective projection (pixels per view-space unit), y up like NDC.
    float3 j0 = float3(u.focal.x / d, 0.0, u.focal.x * t.x / (d * d));
    float3 j1 = float3(0.0, u.focal.y / d, u.focal.y * t.y / (d * d));
    float a = dot(j0, C * j0) + 0.3;
    float b = dot(j0, C * j1);
    float c = dot(j1, C * j1) + 0.3;
    float mid = 0.5 * (a + c);
    float disc = sqrt(max(mid * mid - (a * c - b * b), 0.0));
    float l1 = mid + disc;
    float l2 = max(mid - disc, 0.0);
    float2 v1 = abs(b) > 1e-7 ? normalize(float2(b, l1 - a)) : (a >= c ? float2(1, 0) : float2(0, 1));
    float2 v2 = float2(-v1.y, v1.x);
    // Draw only as far out as the splat stays visible: alpha·exp(-k²/2) = 1/255 → k = sqrt(2·ln(255·alpha)).
    // Faint splats get much smaller quads than a fixed 3σ — far less overdraw, the main cost on phones.
    float alpha0 = float(s.color.a) / 255.0;
    if (alpha0 < 1.5 / 255.0) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float k = min(sqrt(2.0 * log(255.0 * alpha0)), 3.0);
    float r1 = k * sqrt(l1);
    float r2 = k * sqrt(l2);
    // Splats right in front of the lens blow up into screen-sized smears: skip anything wider than ~the screen,
    // and fade splats closer than 15 cm.
    if (r1 > 0.8 * max(u.viewport.x, u.viewport.y) || r1 < 0.3) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }
    if (d < 0.15) { o.color.a *= half(saturate((d - 0.02) / 0.13)); }

    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 offsetPx = corner.x * v1 * r1 + corner.y * v2 * r2;
    float2 ndc = offsetPx / (u.viewport * 0.5);
    o.position = clip + float4(ndc * clip.w, 0.0, 0.0);
    o.local = corner * k;
    return o;
}

fragment half4 gsFragment(GSOut in [[stage_in]]) {
    half r2 = half(dot(in.local, in.local));
    half alpha = in.color.a * exp(-0.5h * r2);
    if (alpha < half(1.0 / 255.0)) {
        discard_fragment();
    }
    return half4(in.color.rgb * alpha, alpha);   // premultiplied, drawn back to front
}

// MARK: - GPU depth sort for the splat viewer (counting sort on 16-bit log-depth keys, all on the GPU every frame)

struct GSSortUniforms {
    float4x4 view;
    float tanX;         // half view width per metre of depth (with margin)
    float tanY;
    uint count;
    float lodFactor;    // focal px / min σ px: splats smaller than that on screen are skipped (0 = off)
};

constant float GS_LOG_NEAR = -5.643856;   // log2(0.02 m)
constant float GS_LOG_FAR  = 10.965784;   // log2(2000 m)
constant uint GS_CULLED = 0xFFFFFFFF;

kernel void gsKeys(uint i [[thread_position_in_grid]],
                   const device GSplat* splats [[ buffer(0) ]],
                   device uint* keys [[ buffer(1) ]],
                   device atomic_uint* hist [[ buffer(2) ]],
                   constant GSSortUniforms& u [[ buffer(3) ]]) {
    if (i >= u.count) return;
    float4 t = u.view * float4(float3(splats[i].position), 1.0);
    float d = -t.z;
    uint key = GS_CULLED;
    bool visible = d >= 0.02 && abs(t.x) <= d * u.tanX + 0.5 && abs(t.y) <= d * u.tanY + 0.5;
    if (visible && u.lodFactor > 0.0) {
        // Distance LOD: far splats that cover only a sliver of a pixel are skipped (σ_screen = σ·focal/d).
        GSplat s = splats[i];
        float sigma2 = max(max(float(s.cov[0]), float(s.cov[3])), float(s.cov[5])) * s.covScale;
        if (sigma2 * u.lodFactor * u.lodFactor < d * d) visible = false;
    }
    if (visible) {
        float f = saturate((log2(d) - GS_LOG_NEAR) / (GS_LOG_FAR - GS_LOG_NEAR));
        key = 65535u - uint(f * 65535.0);           // far = small key = drawn first
        atomic_fetch_add_explicit(&hist[key], 1u, memory_order_relaxed);
    }
    keys[i] = key;
}

// One threadgroup of 256 threads, 256 buckets each: exclusive prefix sum of the 65 536-bucket histogram,
// plus the indirect draw arguments (4 vertices × visible splats).
kernel void gsScan(uint tid [[thread_index_in_threadgroup]],
                   const device uint* hist [[ buffer(0) ]],
                   device uint* offsets [[ buffer(1) ]],
                   device uint* args [[ buffer(2) ]],
                   threadgroup uint* sums [[ threadgroup(0) ]]) {
    uint base = tid * 256u;
    uint s = 0;
    for (uint j = 0; j < 256u; j++) s += hist[base + j];
    sums[tid] = s;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint off = 1; off < 256u; off <<= 1) {
        uint v = tid >= off ? sums[tid - off] : 0u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        sums[tid] += v;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    uint run = sums[tid] - s;
    for (uint j = 0; j < 256u; j++) {
        offsets[base + j] = run;
        run += hist[base + j];
    }
    if (tid == 255u) {
        args[0] = 4u; args[1] = sums[255]; args[2] = 0u; args[3] = 0u;
    }
}

kernel void gsScatter(uint i [[thread_position_in_grid]],
                      const device uint* keys [[ buffer(0) ]],
                      device atomic_uint* offsets [[ buffer(1) ]],
                      device uint* order [[ buffer(2) ]],
                      constant GSSortUniforms& u [[ buffer(3) ]]) {
    if (i >= u.count) return;
    uint k = keys[i];
    if (k == GS_CULLED) return;
    uint pos = atomic_fetch_add_explicit(&offsets[k], 1u, memory_order_relaxed);
    order[pos] = i;
}

// MARK: - Live point cloud on the GPU (recorder): unproject LiDAR depth, keep one point per 2 cm voxel,
// track 10 cm coverage voxels and from how many directions each was seen. Replaces the CPU loop.

struct PCUniforms {
    float4x4 transform;     // camera to world (ARKit)
    float4 intrinsics;      // fx, fy, cx, cy in depth-map pixels
    float4 cameraPos;       // xyz
    float2 imageScale;      // camera image pixels per depth pixel
    uint capacity;
    uint coverageCapacity;
    uint stride;
    float pointSize;
    float maxDepth;
    uint fineMask;          // hash table size - 1
    uint coverageMask;
    uint pad0, pad1, pad2;
};

struct PCCounters {
    atomic_uint written;
    atomic_uint coverageCount;
    atomic_uint wellCovered;
    uint pad;
};

static uint pcHash(int3 c) {
    return (uint(c.x) * 73856093u) ^ (uint(c.y) * 19349663u) ^ (uint(c.z) * 83492791u);
}

static uint pcKey(int3 c) {   // 10 bits per axis (wraps every 1024 voxels), bit 30 set so 0 means empty
    return (uint(c.x) & 0x3FFu) | ((uint(c.y) & 0x3FFu) << 10) | ((uint(c.z) & 0x3FFu) << 20) | (1u << 30);
}

/// Linear-probing insert. Returns 1 = newly inserted, 0 = already there, 2 = table full; slot = table index.
static int pcInsert(device atomic_uint* table, uint mask, uint key, uint hash, thread uint& slot) {
    uint h = hash & mask;
    for (int i = 0; i < 24; i++) {
        uint expected = 0u;
        while (!atomic_compare_exchange_weak_explicit(&table[h], &expected, key, memory_order_relaxed, memory_order_relaxed)) {
            if (expected != 0u) break;   // spurious failure with an empty slot: retry
        }
        if (expected == 0u) { slot = h; return 1; }
        if (expected == key) { slot = h; return 0; }
        h = (h + 1u) & mask;
    }
    return 2;
}

static float4 pcCoverageColor(uint views) {
    if (views <= 1u) return float4(0.95, 0.2, 0.2, 1);
    if (views == 2u) return float4(1.0, 0.6, 0.15, 1);
    if (views == 3u) return float4(0.95, 0.9, 0.2, 1);
    return float4(0.25, 0.85, 0.35, 1);
}

kernel void pcSample(uint2 gid [[thread_position_in_grid]],
                     texture2d<float, access::read> depth [[ texture(0) ]],
                     texture2d<uint, access::read> confidence [[ texture(1) ]],
                     texture2d<float, access::read> lumaTex [[ texture(2) ]],
                     texture2d<float, access::read> chromaTex [[ texture(3) ]],
                     device SFPointVertex* points [[ buffer(0) ]],
                     device SFPointVertex* coverage [[ buffer(1) ]],
                     device PCCounters& counters [[ buffer(2) ]],
                     device atomic_uint* fineTable [[ buffer(3) ]],
                     device atomic_uint* coverageTable [[ buffer(4) ]],
                     device atomic_uint* coverageSlots [[ buffer(5) ]],
                     device atomic_uint* coverageMasks [[ buffer(6) ]],
                     constant PCUniforms& u [[ buffer(7) ]]) {
    uint2 p = gid * u.stride + u.stride / 2u;
    if (p.x >= depth.get_width() || p.y >= depth.get_height()) return;
    float d = depth.read(p).r;
    if (!(d > 0.1 && d < u.maxDepth)) return;
    if (confidence.read(p).r < 2u) return;
    float4 local = float4((float(p.x) - u.intrinsics.z) / u.intrinsics.x * d,
                          -(float(p.y) - u.intrinsics.w) / u.intrinsics.y * d, -d, 1.0);
    float3 world = (u.transform * local).xyz;

    // Coverage (10 cm voxels): which of 16 directions (8 compass sectors × from above / level) saw it.
    int3 cv = int3(floor(world / 0.10));
    uint slot;
    int r = pcInsert(coverageTable, u.coverageMask, pcKey(cv), pcHash(cv), slot);
    if (r != 2) {
        uint index;
        if (r == 1) {
            index = atomic_fetch_add_explicit(&counters.coverageCount, 1u, memory_order_relaxed);
            if (index < u.coverageCapacity) atomic_store_explicit(&coverageSlots[slot], index, memory_order_relaxed);
        } else {
            index = atomic_load_explicit(&coverageSlots[slot], memory_order_relaxed);
        }
        if (index < u.coverageCapacity) {
            float3 toCam = u.cameraPos.xyz - world;
            float len = max(length(toCam), 0.001);
            float yaw = atan2(toCam.x, toCam.z);
            uint sector = uint(clamp(int((yaw + M_PI_F) / (2.0 * M_PI_F) * 8.0), 0, 7));
            uint bit = 1u << (sector + (toCam.y / len > 0.35 ? 8u : 0u));
            uint old = atomic_fetch_or_explicit(&coverageMasks[index], bit, memory_order_relaxed);
            if ((old & bit) == 0u) {
                uint views = popcount(old | bit);
                if (views == 3u) atomic_fetch_add_explicit(&counters.wellCovered, 1u, memory_order_relaxed);
                float3 center = (float3(cv) + 0.5) * 0.10;
                coverage[index].position = float4(center, 0.07);
                coverage[index].color = pcCoverageColor(views);
            }
        }
    }

    // Display points: one per 2 cm voxel.
    int3 fv = int3(floor(world / 0.02));
    uint fslot;
    if (pcInsert(fineTable, u.fineMask, pcKey(fv), pcHash(fv), fslot) != 1) return;
    uint2 ip = min(uint2(float2(p) * u.imageScale), uint2(lumaTex.get_width() - 1, lumaTex.get_height() - 1));
    float y = lumaTex.read(ip).r;
    float2 cbcr = chromaTex.read(ip / 2u).rg - 0.5;
    float3 rgb = saturate(float3(y + 1.402 * cbcr.y, y - 0.344136 * cbcr.x - 0.714136 * cbcr.y, y + 1.772 * cbcr.x));
    uint w = atomic_fetch_add_explicit(&counters.written, 1u, memory_order_relaxed);
    points[w % u.capacity].position = float4(world, u.pointSize);
    points[w % u.capacity].color = float4(rgb, 1.0);
}

/// Appends one point (the camera path) through the same counter.
kernel void pcAppend(uint i [[thread_position_in_grid]],
                     device SFPointVertex* points [[ buffer(0) ]],
                     device PCCounters& counters [[ buffer(2) ]],
                     constant SFPointVertex& extra [[ buffer(3) ]],
                     constant PCUniforms& u [[ buffer(7) ]]) {
    if (i > 0u) return;
    uint w = atomic_fetch_add_explicit(&counters.written, 1u, memory_order_relaxed);
    points[w % u.capacity] = extra;
}
