#include <metal_stdlib>
using namespace metal;

// Block sizes (in pixels) for each masked region plus the mask sampling
// thresholds. Mirrored by `MosaicParams` in MosaicRenderer.swift; keep the
// layouts in sync.
struct MosaicParams {
    float faceBlock;   // block size for the broad face area  (mask ~= 0.4)
    float eyeBlock;    // finer block size for the eyes        (mask ~= 0.7)
    float mouthBlock;  // finest block size for the mouth/lips (mask ~= 1.0)
    float edgeSoftness; // mask value over which the mosaic is fully opaque
    uint  width;
    uint  height;
};

// Picks a block size from the encoded mask value. The mask writes a distinct
// intensity per region (see FaceRegion.maskValue) so a single pass can mosaic
// the face coarsely while keeping eyes and mouth crisp/fine.
static inline float blockSizeForMask(float mask, constant MosaicParams &params) {
    if (mask >= 0.85) {
        return params.mouthBlock;
    } else if (mask >= 0.55) {
        return params.eyeBlock;
    }
    return params.faceBlock;
}

// Average color of the block that `coord` falls into. Sampling the mean (rather
// than a single representative texel) keeps the mosaic stable as the face moves
// sub-block distances between frames.
static inline float4 blockAverage(texture2d<float, access::read> tex,
                                  uint2 coord,
                                  float block,
                                  constant MosaicParams &params) {
    float b = max(block, 1.0);
    uint2 origin = uint2(floor(float2(coord) / b) * b);
    uint maxX = params.width;
    uint maxY = params.height;
    uint step = max(uint(b / 4.0), 1u); // sub-sample large blocks for speed

    float4 sum = float4(0.0);
    float n = 0.0;
    for (uint y = origin.y; y < origin.y + uint(b) && y < maxY; y += step) {
        for (uint x = origin.x; x < origin.x + uint(b) && x < maxX; x += step) {
            sum += tex.read(uint2(x, y));
            n += 1.0;
        }
    }
    return n > 0.0 ? sum / n : tex.read(coord);
}

// Pixelation kernel. For each output texel: if it lies inside the mask, replace
// it with its region's block average and blend along the soft mask edge so the
// mosaic appears to "stick" to the face contour. Pixels outside the mask pass
// through unchanged. This is a from-scratch pixelator — no CIPixellate.
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

    float block = blockSizeForMask(mask, params);
    float4 mosaic = blockAverage(inTexture, gid, block, params);

    // Soft edge: ramp the mosaic in over a thin band so the boundary is not a
    // hard rectangle. `edgeSoftness` is the mask value at which it is fully on.
    float blend = clamp(mask / max(params.edgeSoftness, 0.001), 0.0, 1.0);
    float4 result = mix(original, mosaic, blend);
    result.a = original.a;
    outTexture.write(result, gid);
}
