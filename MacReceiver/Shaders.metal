//
//  Shaders.metal
//  MacReceiver
//
//  v1.1: rotation-aware fullscreen quad. `rotation` is the number of
//  90° clockwise turns to apply to the displayed image (0...3).
//  Rotating here means remapping which texture corner lands on which
//  screen corner — zero extra GPU cost.
//

#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut fullscreenVertex(uint vid [[vertex_id]],
                                  constant float2 &scale    [[buffer(0)]],
                                  constant uint   &rotation [[buffer(1)]]) {
    // Triangle strip: 0 = bottom-left, 1 = bottom-right,
    //                 2 = top-left,    3 = top-right.
    const float2 positions[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
    const float2 baseUVs[4]   = { { 0,  1}, {1,  1}, { 0, 0}, {1, 0} };

    // For each rotation, which base UV goes to which screen corner.
    //   row 0: 0°    row 1: 90° CW    row 2: 180°    row 3: 270° CW
    const uint remap[4][4] = {
        {0, 1, 2, 3},
        {1, 3, 0, 2},
        {3, 2, 1, 0},
        {2, 0, 3, 1},
    };

    VertexOut out;
    out.position = float4(positions[vid] * scale, 0.0, 1.0);
    out.uv = baseUVs[remap[rotation & 3][vid]];
    return out;
}

fragment float4 nv12Fragment(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> yTexture    [[texture(0)]],
                             texture2d<float, access::sample> cbcrTexture [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float y  = (yTexture.sample(s, in.uv).r - 16.0/255.0) * (255.0/219.0);
    float2 c = (cbcrTexture.sample(s, in.uv).rg - 128.0/255.0) * (255.0/224.0);

    float3 rgb = float3(
        y + 1.5748 * c.y,
        y - 0.1873 * c.x - 0.4681 * c.y,
        y + 1.8556 * c.x
    );
    return float4(saturate(rgb), 1.0);
}
