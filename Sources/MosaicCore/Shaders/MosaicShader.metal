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

// ===========================================================================
// Mesh-mapped mosaic (TikTok-style 3D look)
//
// Two render passes warp the face through a frontal canonical layout:
//   1) frontalize: draw the posed face mesh into a frontal canvas
//      (vertex position = frontal UV, sampling the input at the posed UV)
//   2) (compute) block-average the frontal canvas into crisp squares
//   3) rewarp: draw the mesh back at the posed positions, sampling the
//      pixelated frontal canvas (nearest, so blocks stay crisp). Because the
//      blocks are square in frontal space, they foreshorten on the posed face
//      and appear to wrap the 3D surface.
// Each vertex buffer entry is a float4: xy = frontal UV [0,1], zw = posed UV [0,1].
// ===========================================================================

struct MeshVaryings {
    float4 position [[position]];
    float2 tex;
};

static inline float4 uvToClip(float2 uv) {
    return float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
}

vertex MeshVaryings meshFrontalizeVertex(uint vid [[vertex_id]],
                                         constant float4 *verts [[buffer(0)]]) {
    float4 v = verts[vid];
    MeshVaryings out;
    out.position = uvToClip(v.xy);   // frontal layout
    out.tex = v.zw;                  // sample input at posed position
    return out;
}

vertex MeshVaryings meshRewarpVertex(uint vid [[vertex_id]],
                                     constant float4 *verts [[buffer(0)]]) {
    float4 v = verts[vid];
    MeshVaryings out;
    out.position = uvToClip(v.zw);   // posed layout (screen)
    out.tex = v.xy;                  // sample frontal pixelated canvas
    return out;
}

fragment float4 meshSampleLinear(MeshVaryings in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    return tex.sample(smp, in.tex);
}

fragment float4 meshSampleNearest(MeshVaryings in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::nearest);
    return tex.sample(smp, in.tex);
}

// Block-average the frontal canvas into crisp axis-aligned squares.
kernel void meshPixelateKernel(texture2d<float, access::read>  inTexture  [[texture(0)]],
                               texture2d<float, access::write> outTexture [[texture(1)]],
                               constant float                  &block      [[buffer(0)]],
                               uint2                            gid        [[thread_position_in_grid]]) {
    uint w = inTexture.get_width();
    uint h = inTexture.get_height();
    if (gid.x >= w || gid.y >= h) {
        return;
    }
    float b = max(block, 1.0);
    uint2 origin = uint2(floor(float2(gid) / b) * b);
    uint step = max(uint(b / 6.0), 1u);
    float4 sum = float4(0.0);
    float n = 0.0;
    for (uint y = origin.y; y < origin.y + uint(b) && y < h; y += step) {
        for (uint x = origin.x; x < origin.x + uint(b) && x < w; x += step) {
            float4 c = inTexture.read(uint2(x, y));
            // Skip un-covered (transparent/black) canvas texels so the average
            // reflects only the warped face, not the empty background.
            if (c.a > 0.01) {
                sum += c;
                n += 1.0;
            }
        }
    }
    float4 avg = n > 0.0 ? sum / n : inTexture.read(gid);
    outTexture.write(avg, gid);
}

// ===========================================================================
// Text overlay (E3-2)
//
// Composites a pre-rasterized text bitmap (straight text image drawn by the
// app layer's CoreText path) onto the mosaic output. Out-of-place like
// `mosaicKernel`: reads `inTexture` (the mosaic result so far), writes
// `outTexture`. The quad's placement/size in canvas pixels is computed once
// per frame by `TextQuadLayout.compute` (pure Swift, shared by preview and
// export) and passed in as `TextOverlayParams`; this kernel only samples and
// alpha-blends, it does no layout math of its own — the "same formula" rule
// for animation lives entirely on the Swift side.
// ===========================================================================

struct TextOverlayParams {
    float originX;   // quad top-left, canvas px
    float originY;
    float width;      // quad size, canvas px
    float height;
    float opacity;    // 0...1, multiplies the bitmap's own alpha
    uint  canvasWidth;
    uint  canvasHeight;
};

kernel void textOverlayKernel(texture2d<float, access::read>   inTexture   [[texture(0)]],
                              texture2d<float, access::write>  outTexture  [[texture(1)]],
                              texture2d<float, access::sample> textTexture [[texture(2)]],
                              constant TextOverlayParams        &params     [[buffer(0)]],
                              uint2                              gid        [[thread_position_in_grid]]) {
    if (gid.x >= params.canvasWidth || gid.y >= params.canvasHeight) {
        return;
    }

    float4 base = inTexture.read(gid);

    float2 p = float2(gid) + 0.5;
    float2 local = p - float2(params.originX, params.originY);
    if (local.x < 0.0 || local.y < 0.0 || local.x >= params.width || local.y >= params.height) {
        outTexture.write(base, gid);
        return;
    }

    constexpr sampler textSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = local / float2(params.width, params.height);
    float4 glyph = textTexture.sample(textSampler, uv);

    float alpha = clamp(glyph.a * params.opacity, 0.0, 1.0);
    // `glyph` is premultiplied alpha (matches `MetalTextureUtilities.texture(from:device:)`),
    // so scaling both color and alpha by `alpha` composites correctly with `mix`.
    float4 straightGlyph = glyph.a > 0.0001 ? float4(glyph.rgb / glyph.a, glyph.a) : float4(0.0);
    float4 result = mix(base, float4(straightGlyph.rgb, 1.0), alpha);
    result.a = base.a;
    outTexture.write(result, gid);
}

// ===========================================================================
// Color grade (E4)
//
// Full-screen color correction (brightness/contrast/saturation/warmth), one
// texture read and one write, no branching on the pixel path (only the
// bounds guard, same shape as every other kernel in this file). This is a
// straight transcription of `ColorGrade.apply(r:g:b:)`
// (Sources/MosaicCore/Timeline/ColorGrade.swift) — the Swift function is the
// reference implementation for the formula, this kernel is only a copy of
// it (same split of responsibility as `TextQuadLayout` computing layout in
// Swift and `textOverlayKernel` only sampling/blending it). If the formula
// in `ColorGrade.apply` changes, mirror the change here too.
//
// Applied in display-referred (gamma) space, not linear light — matching
// `blockAverage` above, which also averages in that space (see
// `ColorGrade.apply`'s doc for why: mixing color spaces between the mosaic
// and the grade would make colors disagree at block edges).
//
// Field order/types below must match the Swift-side parameter struct
// exactly (same convention as `TextOverlayParams` / `TextOverlayRenderer`).
// ===========================================================================

struct ColorGradeParams {
    float brightness; // -1...1
    float contrast;   // 0...2
    float saturation; // 0...2
    float warmth;     // -1...1
    uint  width;
    uint  height;
};

kernel void colorGradeKernel(texture2d<float, access::read>  inTexture  [[texture(0)]],
                             texture2d<float, access::write> outTexture [[texture(1)]],
                             constant ColorGradeParams        &params     [[buffer(0)]],
                             uint2                             gid        [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float4 c = inTexture.read(gid);

    // 1) warmth. `k` mirrors `ColorGrade.warmthStrength` in the Swift reference
    //    implementation — keep the two literals in sync.
    const float k = 0.3;
    float r = c.r * (1.0 + k * params.warmth);
    float g = c.g;
    float b = c.b * (1.0 - k * params.warmth);

    // 2) brightness.
    r += params.brightness * 0.5;
    g += params.brightness * 0.5;
    b += params.brightness * 0.5;

    // 3) contrast.
    r = (r - 0.5) * params.contrast + 0.5;
    g = (g - 0.5) * params.contrast + 0.5;
    b = (b - 0.5) * params.contrast + 0.5;

    // 4) saturation, mixed against Rec.709 luma.
    float luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    r = luma + (r - luma) * params.saturation;
    g = luma + (g - luma) * params.saturation;
    b = luma + (b - luma) * params.saturation;

    // 5) clamp. Alpha passes through unchanged (same convention as every
    //    other kernel in this file).
    float4 result = float4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), clamp(b, 0.0, 1.0), c.a);
    outTexture.write(result, gid);
}

// ===========================================================================
// Orientation (90° rotation + horizontal mirror) — photo mode Step 5.
//
// Field order/types below must match the Swift-side parameter struct
// exactly (same convention as `ColorGradeParams` / `ColorGradeRenderer`).
//
// 90 度単位の回転のみを扱うので補間は行わない（各出力画素は入力画素 1 個の厳密なコピー）。
// `mirror` は回転の**内側**に適用する（`ClipOrientation` の正準形「回転 ∘ 左右反転」に
// 一致させる——`ClipOrientation.map(_:CGPoint)` の doc 参照）。
// ===========================================================================

struct OrientationParams {
    uint rotation;   // 時計回りの度数: 0 / 90 / 180 / 270
    uint isMirrored; // 0/1
    uint outWidth;
    uint outHeight;
};

kernel void orientationKernel(texture2d<float, access::read>  inTexture  [[texture(0)]],
                              texture2d<float, access::write> outTexture [[texture(1)]],
                              constant OrientationParams       &params     [[buffer(0)]],
                              uint2                             gid        [[thread_position_in_grid]]) {
    if (gid.x >= params.outWidth || gid.y >= params.outHeight) {
        return;
    }

    int inWidth = int(inTexture.get_width());
    int inHeight = int(inTexture.get_height());
    int gx = int(gid.x);
    int gy = int(gid.y);

    // 出力座標 → 回転前・反転後の座標への逆写像（`ClipOrientation.map` の逆）。
    int mx;
    int my;
    switch (params.rotation) {
        case 90u:
            mx = gy;
            my = int(params.outWidth) - 1 - gx;
            break;
        case 180u:
            mx = int(params.outWidth) - 1 - gx;
            my = int(params.outHeight) - 1 - gy;
            break;
        case 270u:
            mx = int(params.outHeight) - 1 - gy;
            my = gx;
            break;
        default:
            mx = gx;
            my = gy;
            break;
    }

    // 反転は回転の内側（素材に先に掛かる）。
    int px = params.isMirrored != 0 ? (inWidth - 1 - mx) : mx;
    int py = my;
    px = clamp(px, 0, inWidth - 1);
    py = clamp(py, 0, inHeight - 1);

    float4 c = inTexture.read(uint2(uint(px), uint(py)));
    outTexture.write(c, gid);
}

// ===========================================================================
// Letterbox background (S13)
//
// Fills the margin that appears when the source does not fill the output
// frame. Two modes: solid colour, or a blurred, enlarged copy of the content.
//
// **The input MUST already have the mosaic burned in.** The blur is built by
// sampling this same texture, so feeding a pre-mosaic frame would put the
// unmasked faces into the margin, enlarged. Blur is not a masking technique.
// See `TimelineBackground` (Swift side) for the full reasoning.
//
// Field order/types below must match the Swift-side parameter struct exactly
// (same convention as `ColorGradeParams` / `TextOverlayParams`).
// ===========================================================================

struct LetterboxParams {
    // Content rect in normalised frame coordinates (origin top-left).
    float contentMinX;
    float contentMinY;
    float contentMaxX;
    float contentMaxY;
    // Solid fill, also used where the blur has no content to sample.
    float fillR;
    float fillG;
    float fillB;
    // Box-blur radius in pixels. 0 means "solid fill only".
    float blurRadius;
    uint  width;
    uint  height;
};

kernel void letterboxKernel(texture2d<float, access::read>  inTexture  [[texture(0)]],
                            texture2d<float, access::write> outTexture [[texture(1)]],
                            constant LetterboxParams        &params    [[buffer(0)]],
                            uint2                            gid       [[thread_position_in_grid]]) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float w = float(params.width);
    float h = float(params.height);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    // Inside the content rect the frame is passed through untouched. The
    // margin is the only thing this kernel is allowed to change.
    if (uv.x >= params.contentMinX && uv.x <= params.contentMaxX &&
        uv.y >= params.contentMinY && uv.y <= params.contentMaxY) {
        outTexture.write(inTexture.read(gid), gid);
        return;
    }

    float3 fill = float3(params.fillR, params.fillG, params.fillB);
    if (params.blurRadius <= 0.0) {
        outTexture.write(float4(fill, 1.0), gid);
        return;
    }

    // Content rect in pixels.
    float cx0 = params.contentMinX * w;
    float cy0 = params.contentMinY * h;
    float cx1 = params.contentMaxX * w;
    float cy1 = params.contentMaxY * h;
    float cw = max(cx1 - cx0, 1.0);
    float ch = max(cy1 - cy0, 1.0);

    // "Cover" mapping: blow the content up until it covers the whole frame,
    // then read from it. This is what the margin shows — the same picture,
    // enlarged and blurred, which is the familiar look from other editors.
    float scale = max(w / cw, h / ch);
    float2 frameCenter = float2(w, h) * 0.5;
    float2 contentCenter = float2(cx0 + cw * 0.5, cy0 + ch * 0.5);
    float2 src = contentCenter + (float2(gid) + 0.5 - frameCenter) / scale;

    // Sparse box blur. Taps are spread over the radius rather than sampling
    // every pixel: the content is already magnified by `scale`, so the high
    // frequencies are gone and a dense kernel would only cost time.
    const int kTaps = 4; // (2*4+1)^2 = 81 samples
    float step = max(params.blurRadius / float(kTaps), 1.0);
    float3 sum = float3(0.0);
    float count = 0.0;
    for (int dy = -kTaps; dy <= kTaps; ++dy) {
        for (int dx = -kTaps; dx <= kTaps; ++dx) {
            float2 p = src + float2(float(dx), float(dy)) * step;
            // Clamp into the content rect: never sample the margin itself,
            // otherwise the fill colour bleeds in and the edges go dark.
            p.x = clamp(p.x, cx0, cx1 - 1.0);
            p.y = clamp(p.y, cy0, cy1 - 1.0);
            sum += inTexture.read(uint2(uint(p.x), uint(p.y))).rgb;
            count += 1.0;
        }
    }
    float3 blurred = count > 0.0 ? sum / count : fill;
    outTexture.write(float4(blurred, 1.0), gid);
}
