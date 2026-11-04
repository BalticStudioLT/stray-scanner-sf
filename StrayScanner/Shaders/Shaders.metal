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
