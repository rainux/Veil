#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 fgColor  [[attribute(2)]];
    float4 bgColor  [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
};

struct Uniforms {
    float2 viewportSize;
};

vertex VertexOut vertexShader(VertexIn in [[stage_in]],
                              constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    float2 clipPos = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
    clipPos.y = -clipPos.y;
    out.position = float4(clipPos, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.fgColor = in.fgColor;
    out.bgColor = in.bgColor;
    return out;
}

// The atlas stores glyphs as white alpha masks (rendered in white on transparent
// background). This fragment shader colorizes them using the per-vertex fgColor,
// allowing a single atlas entry to serve all color combinations.
//
// Three quad types flow through this shader:
//   1. Background quads:  texAlpha=0 (sentinel pixel), bgColor=solid → outputs bgColor
//   2. Glyph quads:       texAlpha=glyph shape, fgColor=text color, bgColor=transparent
//                          → outputs fgColor modulated by glyph alpha
//   3. Debug overlay:     fgColor.a=0 flags pre-colored texture → passes through texColor
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::nearest, min_filter::nearest);
    float4 texColor = atlas.sample(texSampler, in.texCoord);

    // fgColor.a == 0 && bgColor.a == 0 signals a pre-colored texture (debug
    // overlay) that should pass through without colorization
    if (in.fgColor.a == 0 && in.bgColor.a == 0) {
        return texColor;
    }

    // Colorize the white alpha mask with the per-vertex foreground color,
    // then blend over the background color
    float4 glyph = float4(in.fgColor.rgb * texColor.a, texColor.a);
    return mix(in.bgColor, glyph, texColor.a);
}
