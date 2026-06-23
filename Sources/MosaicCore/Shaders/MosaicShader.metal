#include <metal_stdlib>
using namespace metal;

// A single uniform block size (in pixels) for every masked region, plus the
// mask sampling threshold. Mirrored by `MosaicParams` in MosaicRenderer.swift;
// keep the layouts in sync. Strength is tuned through `block` from the UI slider.
struct MosaicParams {
    float block;        // uniform mosaic block size for all masked regions
    float edgeSoftness; // mask value over which the mosaic is fully opaque
    float rotation;     // face roll (radians); block grid rotates to match
    float centerX;      // face center the grid is anchored to / rotated about
    float centerY;
    uint  width;
    uint  height;
};

// Average color of the block that `coord` falls into, in a frame rotated by
// `rotation` about the face center. Quantizing in the rotated frame makes the
// mosaic blocks follow a tilted face (they "stick" to it) while staying crisp.
// Sampling the mean (rather than one texel) keeps the mosaic stable frame to
// frame. With rotation 0 this reduces to an axis-aligned grid.
static inline float4 blockAverage(texture2d<float, access::read> tex,
                                  uint2 coord,
                                  constant MosaicParams &params) {
    float b = max(params.block, 1.0);
    float2 center = float2(params.centerX, params.centerY);
    float ct = cos(params.rotation);
    float st = sin(params.rotation);

    // Into the face-aligned (upright) frame, then quantize to the block cell.
    float2 d = float2(coord) - center;
    float2 u = float2(d.x * ct + d.y * st, -d.x * st + d.y * ct);
    float2 cellMin = floor(u / b) * b;

    uint step = max(uint(b / 4.0), 1u); // sub-sample large blocks for speed
    int maxX = int(params.width);
    int maxY = int(params.height);

    float4 sum = float4(0.0);
    float n = 0.0;
    for (float yy = cellMin.y; yy < cellMin.y + b; yy += float(step)) {
        for (float xx = cellMin.x; xx < cellMin.x + b; xx += float(step)) {
            // Back to screen space.
            float2 s = center + float2(xx * ct - yy * st, xx * st + yy * ct);
            int2 si = int2(round(s));
            if (si.x >= 0 && si.y >= 0 && si.x < maxX && si.y < maxY) {
                sum += tex.read(uint2(si));
                n += 1.0;
            }
        }
    }
    return n > 0.0 ? sum / n : tex.read(coord);
}

// Pixelation kernel. For each output texel: if it lies inside the mask, replace
// it with its block average and blend along the soft mask edge so the mosaic
// appears to "stick" to the face contour. Pixels outside the mask pass through
// unchanged. This is a from-scratch pixelator — no CIPixellate.
kernel void mosaicKernel(texture2d<float, access::read>  inTexture   [[texture(0)]],
                         texture2d<float, access::write> outTexture  [[texture(1)]],
                         texture2d<float, access::sample> maskTexture [[texture(2)]],
                         constant MosaicParams           &params      [[buffer(0)]],
                         uint2                            gid         [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float4 original = inTexture.read(gid);

    constexpr sampler maskSampler(coord::normalized,
                                  address::clamp_to_edge,
                                  filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(params.width, params.height);
    float mask = maskTexture.sample(maskSampler, uv).r;

    if (mask <= 0.001) {
        outTexture.write(original, gid);
        return;
    }

    float4 mosaic = blockAverage(inTexture, gid, params);

    // Soft edge: ramp the mosaic in over a thin band so the boundary is not a
    // hard rectangle. `edgeSoftness` is the mask value at which it is fully on.
    float blend = clamp(mask / max(params.edgeSoftness, 0.001), 0.0, 1.0);
    float4 result = mix(original, mosaic, blend);
    result.a = original.a;
    outTexture.write(result, gid);
}
