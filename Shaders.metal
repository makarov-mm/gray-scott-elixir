//  Shaders.metal — GrayScottMetal
//  Fullscreen triangle sampling the V field texture (r8Unorm),
//  colormap applied in the fragment shader:
//  deep navy -> teal -> amber -> white.

#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut field_vertex(uint vid [[vertex_id]],
                         constant float2 &viewScale [[buffer(0)]])
{
    // one triangle covering the screen: (-1,-1) (3,-1) (-1,3)
    float2 pos = float2((vid == 1) ? 3.0 : -1.0,
                        (vid == 2) ? 3.0 : -1.0);
    VOut out;
    out.position = float4(pos * viewScale, 0.0, 1.0);
    out.uv = pos * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

static float3 colormap(float t)
{
    const float3 c0 = float3(0.02, 0.03, 0.10);   // navy
    const float3 c1 = float3(0.05, 0.45, 0.50);   // teal
    const float3 c2 = float3(0.95, 0.70, 0.25);   // amber
    const float3 c3 = float3(1.00, 0.98, 0.92);   // near-white

    if (t < 0.33) return mix(c0, c1, t / 0.33);
    if (t < 0.66) return mix(c1, c2, (t - 0.33) / 0.33);
    return mix(c2, c3, (t - 0.66) / 0.34);
}

fragment float4 field_fragment(VOut in [[stage_in]],
                               texture2d<float> field [[texture(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear,
                          address::clamp_to_edge);
    float v = field.sample(smp, in.uv).r;
    // stretch: V rarely exceeds ~0.45 in the coral regime
    float t = clamp(v * 2.4, 0.0, 1.0);
    return float4(colormap(t), 1.0);
}
