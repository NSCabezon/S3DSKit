#include <metal_stdlib>
using namespace metal;

// Rotate eye images 90° CW into the frames the 3DS decodes straight into its framebuffers
// (see docs/ARCHITECTURE.md). Each eye image is 400x240 (origin top-left).
//   stacked 240x800 (params.singleEye == 0):
//     out (col c 0..239, row r 0..799): eye = r < 400 ? L : R; sx = r % 400; sy = 239 - c
//   alternating 240x400 (params.singleEye == 1 left / 2 right):
//     out (col c 0..239, row r 0..399): sx = r; sy = 239 - c
//   out(c, r) = eye(sx, sy)
// Each eye image is produced from a source texture of any size: uv = (p - offset) * scale
// (p = normalized eye pixel center; S3DSFitTransform in Swift), black outside [0,1], with an
// n x n grid of bilinear taps over the pixel footprint to avoid aliasing when downscaling.
// Must stay layout-compatible with RotateParams in FrameRotator.swift.

struct S3DSEyeParams {
    float2 scale;
    float2 offset;
    float2 footprint;   // uv extent of one eye pixel
    uint   taps;        // n (1..4)
    uint   encodeSRGB;  // 1: reads return linear (sRGB/float formats) -> re-encode to sRGB
};

struct S3DSRotateParams {
    S3DSEyeParams eyes[2];
    uint flipY;
    uint singleEye;   // 0: stacked (both eyes, 800 rows); 1: left only; 2: right only (400 rows)
};

static inline float3 s3ds_linear_to_srgb(float3 c) {
    c = saturate(c);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(hi, lo, c <= 0.0031308);
}

static inline float3 s3ds_eye_color(texture2d<float, access::sample> tex,
                                    constant S3DSEyeParams &e, uint sx, uint sy, bool flipY)
{
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 p = float2((float(sx) + 0.5) / 400.0, (float(sy) + 0.5) / 240.0);
    float2 uv = (p - e.offset) * e.scale;
    if (any(uv < 0.0) || any(uv > 1.0)) { return float3(0.0); }
    if (flipY) { uv.y = 1.0 - uv.y; }
    const uint n = clamp(e.taps, 1u, 4u);
    float3 acc = float3(0.0);
    for (uint j = 0; j < n; ++j) {
        for (uint i = 0; i < n; ++i) {
            float2 o = (float2(float(i), float(j)) + 0.5) / float(n) - 0.5;
            acc += tex.sample(s, uv + o * e.footprint, level(0)).rgb;
        }
    }
    float3 rgb = acc / float(n * n);
    return e.encodeSRGB != 0 ? s3ds_linear_to_srgb(rgb) : saturate(rgb);
}

kernel void s3ds_rotate_stack(texture2d<float, access::sample> leftEye  [[texture(0)]],
                              texture2d<float, access::sample> rightEye [[texture(1)]],
                              texture2d<float, access::write>  outFrame [[texture(2)]],
                              constant S3DSRotateParams &params         [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    const uint rows = params.singleEye == 0 ? 800u : 400u;
    if (gid.x >= 240 || gid.y >= rows) { return; }
    const uint c = gid.x;
    const uint r = gid.y;
    const uint sx = r % 400;
    const uint sy = 239 - c;
    const bool isLeft = params.singleEye == 0 ? (r < 400) : (params.singleEye == 1);
    float3 rgb = isLeft ? s3ds_eye_color(leftEye, params.eyes[0], sx, sy, params.flipY != 0)
                        : s3ds_eye_color(rightEye, params.eyes[1], sx, sy, params.flipY != 0);
    outFrame.write(float4(rgb, 1.0), gid);
}
