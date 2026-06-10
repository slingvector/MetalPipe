//
//  Shaders.metal
//  MacReceiver
//
//  Fullscreen quad + BT.709 video-range NV12 → RGB.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]],
                                  constant float2 &scale [[buffer(0)]]) {
    // Triangle strip covering NDC, scaled for aspect-fit letterboxing.
    const float2 positions[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
    const float2 uvs[4]       = { { 0,  1}, {1,  1}, { 0, 0}, {1, 0} };

    VertexOut out;
    out.position = float4(positions[vid] * scale, 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 nv12Fragment(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> yTexture    [[texture(0)]],
                             texture2d<float, access::sample> cbcrTexture [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    // Video-range expansion (BT.709)
    float y  = (yTexture.sample(s, in.uv).r - 16.0/255.0) * (255.0/219.0);
    float2 c = (cbcrTexture.sample(s, in.uv).rg - 128.0/255.0) * (255.0/224.0);

    float3 rgb = float3(
        y + 1.5748 * c.y,
        y - 0.1873 * c.x - 0.4681 * c.y,
        y + 1.8556 * c.x
    );
    return float4(saturate(rgb), 1.0);
}
