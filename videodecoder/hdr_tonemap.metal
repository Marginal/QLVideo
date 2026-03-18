#include <metal_stdlib>
using namespace metal;

// FFmpeg constants passed in uniforms
constant uint RANGE_MPEG = 1;  // AVCOL_RANGE_MPEG (limited range YUV, default for broadcast HDR)
constant uint RANGE_JPEG = 2;  // AVCOL_RANGE_JPEG (full range YUV)
constant uint TRC_SMPTE2084 = 16;  // AVCOL_TRC_SMPTE2084 (PQ)
constant uint TRC_ARIB_STD_B67 = 18;  // AVCOL_TRC_ARIB_STD_B67 (HLG)

struct HDRParams {
    uint srcWidth;
    uint srcHeight;
    uint dstWidth;
    uint dstHeight;
    float scenePeak;    // in nits (cd/m²)
    uint colorTransfer;
    uint colorRange;
};

// ---------------------------------------------------------------------------
// Step 1: BT.2020 NCL YUV → RGB matrix (operates on PQ-domain signal values)
// ---------------------------------------------------------------------------
// y in [0,1], u/v in [-0.5,0.5]
inline float3 yuvToRGB_BT2020(float y, float u, float v) {
    float r = y                   + 1.47460 * v;
    float g = y - 0.16455 * u - 0.57135 * v;
    float b = y + 1.88140 * u;
    return float3(r, g, b);
}

// ---------------------------------------------------------------------------
// Step 2: Inverse PQ (SMPTE ST 2084 EOTF)
// Input:  PQ non-linear signal E' in [0,1]
// Output: linear light in [0,1] where 1.0 = 10000 nits
// ---------------------------------------------------------------------------
constant float PQ_M1 = 0.1593017578125;     // 2610/16384
constant float PQ_M2 = 78.84375;            // 2523/32 * 128
constant float PQ_C1 = 0.8359375;           // 3424/4096
constant float PQ_C2 = 18.8515625;          // 2413/128
constant float PQ_C3 = 18.6875;             // 2392/128

inline float inversePQ(float x) {
    float xp = pow(max(x, 0.0f), 1.0f / PQ_M2);
    float num = max(xp - PQ_C1, 0.0f);
    float den = PQ_C2 - PQ_C3 * xp;
    return pow(num / den, 1.0f / PQ_M1);
}

inline float3 inversePQ3(float3 c) {
    return float3(inversePQ(c.r), inversePQ(c.g), inversePQ(c.b));
}

// ---------------------------------------------------------------------------
// Step 2 (alt): Inverse HLG (ARIB STD-B67) OETF → scene-linear
// Then apply OOTF to get display-linear, scaled so 1.0 ≈ 1000 nits peak.
// ---------------------------------------------------------------------------
constant float HLG_A = 0.17883277;
constant float HLG_B = 0.28466892;  // 1 - 4*A
constant float HLG_C = 0.55991073;  // 0.5 - A * ln(4*A)

inline float inverseHLG_OETF(float x) {
    // HLG OETF⁻¹: signal → scene-linear [0,1]
    if (x <= 0.5) {
        return (x * x) / 3.0;
    } else {
        return (exp((x - HLG_C) / HLG_A) + HLG_B) / 12.0;
    }
}

inline float3 inverseHLG3(float3 c, float scenePeakNits) {
    // Inverse HLG OETF → scene-referred linear
    float3 scene = float3(
        inverseHLG_OETF(c.r),
        inverseHLG_OETF(c.g),
        inverseHLG_OETF(c.b)
    );

    // BT.2100 HLG OOTF: display = scene^gamma, gamma depends on peak luminance
    // For 1000 nit display, gamma ≈ 1.2
    float gamma = 1.2 + 0.42 * log10(scenePeakNits / 1000.0);
    gamma = clamp(gamma, 1.0, 1.5);

    // Luminance of scene-referred signal (BT.2020 luminance coefficients)
    float Ys = dot(scene, float3(0.2627, 0.6780, 0.0593));
    float Ys_pow = pow(max(Ys, 1e-6), gamma - 1.0);

    // Display-referred = scene * Ys^(gamma-1), then normalize to [0,1] for 10000 nit scale
    float3 display = scene * Ys_pow;
    return display * (scenePeakNits / 10000.0);
}

// ---------------------------------------------------------------------------
// Step 3: Tone mapping — max-RGB with Möbius/knee curve
// Operates in linear light, BT.2020 primaries.
// Input:  linear RGB in absolute units where 1.0 = 10000 nits.
// Output: linear RGB in display-referred units where 1.0 = SDR white.
// peakNorm = scenePeak / 10000.
//
// Uses max(R,G,B) as the mapping signal, which naturally constrains
// saturation by ensuring the brightest channel is compressed.
//
// The curve is linear (1:1) up to a knee point, then smoothly compresses
// the HDR range above into the remaining headroom. This preserves SDR
// content brightness perfectly and only rolls off highlights.
// ---------------------------------------------------------------------------

// Möbius tone mapping curve (used by mpv/libplacebo):
//   Below the knee: linear passthrough (1:1)
//   Above the knee: smooth hyperbolic compression to [knee, 1.0]
// x, peak are in SDR-white-relative units (1.0 = SDR white)
inline float mobiusCurve(float x, float peak) {
    // Knee point: below this, output = input (linear passthrough)
    // Using 0.7 gives good SDR preservation while leaving room for highlights
    const float knee = 0.7;

    if (x <= knee) return x;

    // Fit a Möbius function f(x) = (a*x + b) / (x + c) such that:
    //   f(knee) = knee         (continuity)
    //   f'(knee) = 1           (smooth join, slope = 1)
    //   f(peak) = 1.0          (peak maps to 1.0)
    float a = (peak + knee * knee - 2.0 * knee) / (peak - 1.0);
    float c = a - 2.0 * knee;
    float b = knee * knee + knee * c - a * knee;
    return (a * x + b) / (x + c);
}

inline float3 tonemapMobius(float3 rgb, float peakNorm) {
    float maxC = max(rgb.r, max(rgb.g, rgb.b));
    if (maxC <= 0.0) return float3(0.0);

    // SDR reference white at 203 nits (ITU-R BT.2408 reference white)
    float sdrWhite = 203.0 / 10000.0;

    // Normalize max channel and scene peak to SDR-white units
    float sig  = maxC / sdrWhite;
    float peak = peakNorm / sdrWhite;

    // Apply Möbius curve to the max-channel signal
    float mapped = mobiusCurve(sig, peak);

    // Scale all channels by the same ratio — preserves hue
    float scale = mapped / sig;
    return rgb * (scale / sdrWhite);
}

// ---------------------------------------------------------------------------
// Step 4: BT.2020 → BT.709 gamut conversion (3×3 matrix on linear RGB)
// ---------------------------------------------------------------------------
inline float3 bt2020_to_bt709(float3 c) {
    // Derived from BT.2020 and BT.709 primary chromaticities via D65 whitepoint
    return float3(
         1.6605 * c.r - 0.5877 * c.g - 0.0728 * c.b,
        -0.1246 * c.r + 1.1330 * c.g - 0.0084 * c.b,
        -0.0182 * c.r - 0.1006 * c.g + 1.1187 * c.b
    );
}

// ---------------------------------------------------------------------------
// Step 5: Linear → sRGB transfer function (IEC 61966-2-1)
// ---------------------------------------------------------------------------
inline float linearToSRGB(float c) {
    if (c <= 0.0031308)
        return 12.92 * c;
    else
        return 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

inline float3 linearToSRGB3(float3 c) {
    return float3(linearToSRGB(c.r), linearToSRGB(c.g), linearToSRGB(c.b));
}

// ===========================================================================
// Main kernel
// ===========================================================================
kernel void hdrTonemapYUV420P10ToBGRA8(
    texture2d<uint, access::read>           yTex       [[texture(0)]],
    texture2d<uint, access::read>           uTex       [[texture(1)]],
    texture2d<uint, access::read>           vTex       [[texture(2)]],
    texture2d<float, access::write>         outTex     [[texture(3)]],
    constant HDRParams&                     params     [[buffer(0)]],
    uint2                                   gid        [[thread_position_in_grid]])
{
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) return;

    // --- Sample 10-bit YUV420 planes ---
    uint2 uvCoord = uint2(gid.x / 2, gid.y / 2);
    uint ySample = yTex.read(gid).r;
    uint uSample = uTex.read(uvCoord).r;
    uint vSample = vTex.read(uvCoord).r;

    float y, u, v;

    if (params.colorRange != RANGE_JPEG) { // Limited range
        y = clamp((float(ySample) -  64.0) / 876.0, 0.0, 1.0);
        u = clamp((float(uSample) - 512.0) / 896.0, -0.5, 0.5);
        v = clamp((float(vSample) - 512.0) / 896.0, -0.5, 0.5);
    } else {  // Full range
        y = clamp(float(ySample) / 1023.0, 0.0, 1.0);
        u = clamp((float(uSample) - 512.0) / 1023.0, -0.5, 0.5);
        v = clamp((float(vSample) - 512.0) / 1023.0, -0.5, 0.5);
    }

    // Step 1: BT.2020 NCL YUV → RGB (still PQ/HLG-encoded, not linear)
    float3 rgb = yuvToRGB_BT2020(y, u, v);
    rgb = clamp(rgb, 0.0, 1.0);

    // Step 2: Transfer function → linear light (in BT.2020 primaries)
    //   Result is normalized so 1.0 = 10000 nits
    float peakNorm = params.scenePeak / 10000.0;  // scene peak in normalized units
    float3 linear;

    if (params.colorTransfer == TRC_SMPTE2084) {
        linear = inversePQ3(rgb);
    } else if (params.colorTransfer == TRC_ARIB_STD_B67) {
        linear = inverseHLG3(rgb, params.scenePeak);
    } else {
        // Fallback: assume gamma 2.2
        linear = pow(rgb, 2.2) * peakNorm;
    }

    // Step 3: Tone map — HDR linear to SDR linear (still BT.2020 primaries)
    //   Output is display-referred where 1.0 = SDR white (203 nits)
    float3 tonemapped = tonemapMobius(linear, peakNorm);

    // Step 4: BT.2020 → BT.709 gamut conversion
    float3 rgb709 = bt2020_to_bt709(tonemapped);
    rgb709 = clamp(rgb709, 0.0, 1.0);

    // Step 5: Linear → sRGB gamma
    float3 srgb = linearToSRGB3(rgb709);

    // Step 6: Write BGRA8
    outTex.write(float4(srgb.r, srgb.g, srgb.b, 1.0), gid);
}
