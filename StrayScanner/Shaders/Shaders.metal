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
    float viewDepth;    // metres in front of the camera (for AR occlusion)
    uint index [[flat]];         // splat index (training)
    float sigma2D [[flat]];      // on-screen σ in pixels incl. the 0.3 px² low-pass (training, isotropic splats)
    float sigmaProj [[flat]];    // on-screen σ in pixels without the low-pass
};

static GSOut gsProject(uint vid, uint index, const device GSplat* splats, constant GSUniforms& u, const device half* sh);

vertex GSOut gsVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device GSplat* splats [[ buffer(0) ]],
                      const device uint* order [[ buffer(1) ]],
                      constant GSUniforms& u [[ buffer(2) ]],
                      const device half* sh [[ buffer(3) ]]) {
    return gsProject(vid, order[iid], splats, u, sh);
}

/// Same splats front-to-back (reverse of the sorted order) — for the training backward pass.
vertex GSOut gsVertexBack(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device GSplat* splats [[ buffer(0) ]],
                          const device uint* order [[ buffer(1) ]],
                          constant GSUniforms& u [[ buffer(2) ]],
                          const device half* sh [[ buffer(3) ]],
                          const device uint* args [[ buffer(4) ]]) {
    uint n = args[1];
    return gsProject(vid, order[n - 1u - iid], splats, u, sh);
}

/// Everything about one splat on screen, computed once (not per quad corner).
struct GSProjected {
    bool valid;
    float4 clip;
    float2 axis1;      // pixels, already × k
    float2 axis2;
    float k;           // extent in σ
    half4 color;       // SH applied, near fade applied
    float d;
    float sigma2D, sigmaProj;
};

static GSProjected gsProjectSplat(uint index, const device GSplat* splats, constant GSUniforms& u, const device half* sh) {
    GSProjected r;
    r.valid = false;
    r.sigma2D = 1.0; r.sigmaProj = 0.0;
    GSplat s = splats[index];
    r.color = half4(s.color) / 255.0h;
    if (u.hasSH != 0u) {
        // View-dependent colour (degree 1): rgb += C1·(−y·c1 + z·c2 − x·c3), dir from camera to splat.
        float3 dir = normalize(float3(s.position) - u.cameraPos.xyz);
        const device half* c = sh + index * 9u;
        float3 c1 = float3(c[0], c[1], c[2]), c2 = float3(c[3], c[4], c[5]), c3 = float3(c[6], c[7], c[8]);
        float3 add = 0.48860251 * (-dir.y * c1 + dir.z * c2 - dir.x * c3);
        r.color.rgb = half3(saturate(float3(r.color.rgb) + add));
    }
    float4 t = u.view * float4(float3(s.position), 1.0);
    float d = -t.z;                               // distance in front of the camera
    r.d = d;
    if (d < 0.02) return r;
    float4 clip = u.projection * t;
    if (abs(clip.x) > 1.3 * clip.w || abs(clip.y) > 1.3 * clip.w) return r;
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
    float alpha0 = float(s.color.a) / 255.0;
    if (alpha0 < 1.5 / 255.0) return r;
    float k = min(sqrt(2.0 * log(255.0 * alpha0)), 3.0);
    float r1 = k * sqrt(l1);
    float r2 = k * sqrt(l2);
    // Splats right in front of the lens blow up into screen-sized smears: skip anything wider than ~the screen,
    // and fade splats closer than 15 cm.
    if (r1 > 0.8 * max(u.viewport.x, u.viewport.y) || r1 < 0.3) return r;
    if (d < 0.15) { r.color.a *= half(saturate((d - 0.02) / 0.13)); }
    r.valid = true;
    r.clip = clip;
    r.axis1 = v1 * r1;
    r.axis2 = v2 * r2;
    r.k = k;
    r.sigma2D = sqrt(l1);
    r.sigmaProj = sqrt(max(l1 - 0.3, 0.0));
    return r;
}

static GSOut gsProject(uint vid, uint index, const device GSplat* splats, constant GSUniforms& u, const device half* sh) {
    GSOut o;
    o.index = index;
    GSProjected p = gsProjectSplat(index, splats, u, sh);
    o.color = p.color;
    o.local = float2(0);
    o.viewDepth = p.d;
    o.sigma2D = p.sigma2D;
    o.sigmaProj = p.sigmaProj;
    if (!p.valid) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 offsetPx = corner.x * p.axis1 + corner.y * p.axis2;
    float2 ndc = offsetPx / (u.viewport * 0.5);
    o.position = p.clip + float4(ndc * p.clip.w, 0.0, 0.0);
    o.local = corner * p.k;
    return o;
}

/// Compact per-splat screen data written by the sort pass, so the 4 quad corners don't redo the projection.
struct GSPre {                // exactly 28 bytes, 4-byte aligned (the buffer has 32 per splat)
    float clipX, clipY, clipW;  // clip x, y, w (z is unused: no depth test)
    uint color;                 // uchar4 after SH and near fade
    half ax, ay, bx, by;        // the two screen axes in pixels
    half k, pad;
};
static_assert(sizeof(GSPre) <= 32, "GSPre must fit the 32-byte slots");

vertex GSOut gsVertexPre(uint vid [[vertex_id]], uint iid [[instance_id]],
                         const device GSPre* pre [[ buffer(0) ]],
                         const device uint* order [[ buffer(1) ]],
                         constant GSUniforms& u [[ buffer(2) ]]) {
    uint index = order[iid];
    GSPre p = pre[index];
    GSOut o;
    o.index = index;
    o.color = half4(as_type<uchar4>(p.color)) / 255.0h;
    o.viewDepth = p.clipW;
    o.sigma2D = 1.0; o.sigmaProj = 0.0;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float2 offsetPx = corner.x * float2(p.ax, p.ay) + corner.y * float2(p.bx, p.by);
    float2 ndc = offsetPx / (u.viewport * 0.5);
    float w = p.clipW;
    o.position = float4(p.clipX + ndc.x * w, p.clipY + ndc.y * w, 0.5 * w, w);
    o.local = corner * float(p.k);
    return o;
}

struct GSDepthOut {
    half4 color [[color(0)]];
    half4 depth [[color(1)]];   // r = depth·alpha, a = alpha; blended like colour → r/a = composited depth
};

fragment GSDepthOut gsFragmentDepth(GSOut in [[stage_in]]) {
    half r2 = half(dot(in.local, in.local));
    half alpha = in.color.a * exp(-0.5h * r2);
    if (alpha < half(1.0 / 255.0)) {
        discard_fragment();
    }
    GSDepthOut o;
    o.color = half4(in.color.rgb * alpha, alpha);
    o.depth = half4(half(in.viewDepth) * alpha, 0.0h, 0.0h, alpha);
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
                   constant GSSortUniforms& u [[ buffer(3) ]],
                   constant GSUniforms& g [[ buffer(4) ]],
                   const device half* sh [[ buffer(5) ]],
                   device GSPre* pre [[ buffer(6) ]]) {
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
        // Project once here (the vertex shader then only places 4 corners) and drop splats that won't draw.
        GSProjected p = gsProjectSplat(i, splats, g, sh);
        if (p.valid) {
            GSPre q;
            q.clipX = p.clip.x; q.clipY = p.clip.y; q.clipW = p.clip.w;
            q.ax = half(p.axis1.x); q.ay = half(p.axis1.y); q.bx = half(p.axis2.x); q.by = half(p.axis2.y);
            q.color = as_type<uint>(uchar4(saturate(float4(p.color)) * 255.0 + 0.5));
            q.k = half(p.k);
            q.pad = 0.0h;
            pre[i] = q;
            float f = saturate((log2(d) - GS_LOG_NEAR) / (GS_LOG_FAR - GS_LOG_NEAR));
            key = 65535u - uint(f * 65535.0);           // far = small key = drawn first
            atomic_fetch_add_explicit(&hist[key], 1u, memory_order_relaxed);
        }
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

// MARK: - Reduced-resolution splats composited over the AR camera picture

struct CompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeOut fullscreenQuad(uint vid [[vertex_id]]) {
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    CompositeOut o;
    o.position = float4(p, 0.0, 1.0);
    o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return o;
}

struct OcclusionUniforms {
    float3x3 screenToImage;   // screen uv → camera image uv (ARKit displayTransform, inverted)
    float enabled;
};

/// Splats over the camera, hidden where the LiDAR sees something real closer than the splat (hand, person, table).
fragment half4 compositeOccluded(CompositeOut in [[stage_in]],
                                 texture2d<half, access::sample> splats [[ texture(0) ]],
                                 texture2d<half, access::sample> splatDepth [[ texture(1) ]],
                                 texture2d<float, access::sample> realDepth [[ texture(2) ]],
                                 constant OcclusionUniforms& u [[ buffer(0) ]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    half4 c = splats.sample(s, in.uv);
    if (u.enabled < 0.5 || c.a < 0.01h) return c;
    half4 sd = splatDepth.sample(s, in.uv);
    float splatD = float(sd.r) / max(float(sd.a), 1e-3);
    float2 imageUV = (u.screenToImage * float3(in.uv, 1.0)).xy;
    float real = realDepth.sample(s, imageUV).r;
    if (real <= 0.0) return c;
    // Fade over 6 cm so edges don't flicker.
    float visible = saturate((real - splatD) / 0.06 + 1.0);
    return c * half(visible);
}

fragment half4 compositePremultiplied(CompositeOut in [[stage_in]],
                                      texture2d<half, access::sample> splats [[ texture(0) ]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return splats.sample(s, in.uv);   // premultiplied: blended with one / one-minus-source-alpha
}

// MARK: - Sort-free "fast" splats (weighted blended order-independent transparency, McGuire & Bavoil 2013)
// No depth sort at all: every splat adds into two targets, a final pass divides. Slight smearing where surfaces
// overlap, so it is only used while the view moves in the Fastest setting.

struct GSOITOut {
    half4 accum [[color(0)]];    // Σ w·(rgb·α, α)
    half reveal [[color(1)]];    // Π (1 − α)  via blend zero / one-minus-source-colour
};

fragment GSOITOut gsFragmentOIT(GSOut in [[stage_in]]) {
    half r2 = half(dot(in.local, in.local));
    half alpha = in.color.a * exp(-0.5h * r2);
    if (alpha < half(1.0 / 255.0)) {
        discard_fragment();
    }
    float z = in.viewDepth;
    float w = clamp(0.03 / (1e-5 + pow(z / 200.0, 4.0)), 1e-2, 3e3) * float(alpha);
    GSOITOut o;
    o.accum = half4(half3(float3(in.color.rgb) * float(alpha) * w), half(float(alpha) * w));
    o.reveal = alpha;
    return o;
}

fragment half4 oitResolve(CompositeOut in [[stage_in]],
                          texture2d<half, access::read> accum [[ texture(0) ]],
                          texture2d<half, access::read> reveal [[ texture(1) ]]) {
    uint2 p = uint2(in.position.xy);
    half4 a = accum.read(p);
    half r = reveal.read(p).r;
    half coverage = 1.0h - r;
    if (coverage < 0.002h) discard_fragment();
    half3 color = a.rgb / max(a.a, 1e-4h);
    return half4(color * coverage, coverage);   // premultiplied over the background
}


// MARK: - On-phone training (LiDAR-anchored, isotropic splats; positions fixed, colour/opacity/size learnt)
// Forward: the normal viewer pipeline into a float target. Backward: draw the same splats front-to-back with
// programmable blending (reads the running transmittance T and colour-in-front from the tile), which gives every
// fragment exactly what it needs for the analytic gradients of an L1 loss; they are summed with float atomics.

struct TrainParams {   // per splat
    float3 rgb;        // 0…1
    float opacityLogit;
    float logScale;    // σ in metres = exp(logScale)
    float3 position;
};

struct BackOut {
    float T [[color(0)]];
    float4 front [[color(1)]];
};

struct TrainUniforms {
    float gradScale;
};

fragment BackOut gsBackward(GSOut in [[stage_in]],
                            float Tin [[color(0)]],
                            float4 frontIn [[color(1)]],
                            texture2d<float, access::read> rendered [[ texture(0) ]],
                            texture2d<float, access::read> target [[ texture(1) ]],
                            device atomic_float* grads [[ buffer(0) ]],
                            constant TrainUniforms& tu [[ buffer(1) ]]) {
    float r2 = dot(in.local, in.local);
    float o = float(in.color.a);
    float alpha = min(o * exp(-0.5 * r2), 0.99);
    BackOut out;
    out.T = Tin;
    out.front = frontIn;
    if (alpha < 1.0 / 255.0 || Tin < 1e-4) return out;
    uint2 p = uint2(in.position.xy);
    float4 finalRGBA = rendered.read(p);
    // Only pixels the LiDAR splats actually cover teach anything: in empty pixels (sky, far away, no depth) the
    // error would only make nearby splats grow into huge blobs to fill the gap.
    if (finalRGBA.a < 0.5) return out;
    float3 finalC = finalRGBA.rgb;
    float3 I = target.read(p).rgb;
    float3 g = sign(finalC - I) * tu.gradScale;               // dL/dC for L1
    float3 c = float3(in.color.rgb);
    float T = Tin;
    float3 behind = (finalC - frontIn.rgb - T * alpha * c) / max(T * (1.0 - alpha), 1e-4);
    float3 dc = T * alpha * g;
    float dAlpha = T * dot(c - behind, g);
    float dQ = dAlpha * alpha * (1.0 - o);                    // through o = sigmoid(q), α = o·G
    float s2 = in.sigma2D * in.sigma2D;
    float dL = dAlpha * alpha * r2 * (in.sigmaProj * in.sigmaProj) / max(s2, 1e-6);   // through σ = e^l
    device atomic_float* gp = grads + in.index * 5u;
    atomic_fetch_add_explicit(gp + 0, dc.x, memory_order_relaxed);
    atomic_fetch_add_explicit(gp + 1, dc.y, memory_order_relaxed);
    atomic_fetch_add_explicit(gp + 2, dc.z, memory_order_relaxed);
    atomic_fetch_add_explicit(gp + 3, dQ, memory_order_relaxed);
    atomic_fetch_add_explicit(gp + 4, dL, memory_order_relaxed);
    out.T = T * (1.0 - alpha);
    out.front = float4(frontIn.rgb + T * alpha * c, 1.0);
    return out;
}

struct AdamUniforms {
    float lrColor, lrOpacity, lrScale;
    float beta1, beta2, eps;
    float bias1, bias2;        // 1 − β^t
    uint count;
};

kernel void trainAdam(uint i [[thread_position_in_grid]],
                      device TrainParams* params [[ buffer(0) ]],
                      device float* grads [[ buffer(1) ]],
                      device float* m [[ buffer(2) ]],
                      device float* v [[ buffer(3) ]],
                      constant AdamUniforms& a [[ buffer(4) ]]) {
    if (i >= a.count) return;
    float lr[5] = { a.lrColor, a.lrColor, a.lrColor, a.lrOpacity, a.lrScale };
    float step[5];
    for (uint k = 0; k < 5; k++) {
        uint j = i * 5u + k;
        float gk = grads[j];
        grads[j] = 0.0;
        m[j] = a.beta1 * m[j] + (1.0 - a.beta1) * gk;
        v[j] = a.beta2 * v[j] + (1.0 - a.beta2) * gk * gk;
        float mh = m[j] / a.bias1, vh = v[j] / a.bias2;
        step[k] = lr[k] * mh / (sqrt(vh) + a.eps);
    }
    TrainParams p = params[i];
    p.rgb = saturate(p.rgb - float3(step[0], step[1], step[2]));
    p.opacityLogit = clamp(p.opacityLogit - step[3], -9.0, 9.0);
    p.logScale = clamp(p.logScale - step[4], -7.0, -3.2);   // σ 1 mm … 4 cm: splats sit on 1.5 cm LiDAR voxels
    params[i] = p;
}

/// Writes the render buffer (viewer format) from the trainable parameters.
kernel void trainBuild(uint i [[thread_position_in_grid]],
                       const device TrainParams* params [[ buffer(0) ]],
                       device GSplat* splats [[ buffer(1) ]],
                       constant uint& count [[ buffer(2) ]]) {
    if (i >= count) return;
    TrainParams p = params[i];
    GSplat s;
    s.position = packed_float3(p.position);
    float sigma = exp(p.logScale);
    s.cov[0] = 1.0h; s.cov[1] = 0.0h; s.cov[2] = 0.0h; s.cov[3] = 1.0h; s.cov[4] = 0.0h; s.cov[5] = 1.0h;
    s.covScale = sigma * sigma;
    float o = 1.0 / (1.0 + exp(-p.opacityLogit));
    s.color = uchar4(uchar3(saturate(p.rgb) * 255.0 + 0.5), uchar(saturate(o) * 255.0 + 0.5));
    splats[i] = s;
}
