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
    uint pad;
};

struct GSUniforms {
    float4x4 view;
    float4x4 projection;
    float2 viewport;    // pixels
    float2 focal;       // pixels
};

struct GSOut {
    float4 position [[position]];
    float2 local;       // position inside the splat in standard deviations
    half4 color;
};

vertex GSOut gsVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device GSplat* splats [[ buffer(0) ]],
                      const device uint* order [[ buffer(1) ]],
                      constant GSUniforms& u [[ buffer(2) ]]) {
    GSOut o;
    GSplat s = splats[order[iid]];
    o.color = half4(s.color) / 255.0h;
    o.local = float2(0);
    float4 t = u.view * float4(float3(s.position), 1.0);
    float d = -t.z;                               // distance in front of the camera
    if (d < 0.02) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }
    float4 clip = u.projection * t;
    if (abs(clip.x) > 1.3 * clip.w || abs(clip.y) > 1.3 * clip.w) { o.position = float4(2.0, 2.0, 2.0, 1.0); return o; }

    float3x3 W = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
    float3x3 S = float3x3(float3(s.cov[0], s.cov[1], s.cov[2]),
                          float3(s.cov[1], s.cov[3], s.cov[4]),
                          float3(s.cov[2], s.cov[4], s.cov[5]));
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
