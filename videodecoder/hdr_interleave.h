//
//  hdr_interleave.h
//  QLVideo
//
//  NEON-vectorizable helpers for converting planar YUV to biplanar P010.
//

#ifndef hdr_interleave_h
#define hdr_interleave_h

#include <stdint.h>

// Shift-copy a plane of 16-bit samples. Strides are in units of uint16_t (not bytes).
void hdr_shift_copy(
    const uint16_t *src, uint16_t *dst,
    int width, int srcStride, int dstStride,
    int height, int shift);

// Shift and interleave two planes into one interleaved plane (e.g. Cb+Cr -> CbCr).
// dstStride is in units of uint16_t and covers the full interleaved width.
void hdr_interleave_and_shift(
    const uint16_t *srcCb, const uint16_t *srcCr,
    uint16_t *dst,
    int uvWidth, int srcCbStride, int srcCrStride, int dstStride,
    int uvHeight, int shift);

// Fill a 16-bit luma plane with a single value.
// dst points to the first pixel, stride is in uint16_t elements (not bytes),
// width/height are in pixels.
void y_fill_u16(uint16_t *dst, int width, int height, int dstStride, uint16_t value);

// Fill an interleaved 16-bit CbCr plane with a constant pair.
// Layout: Cb0, Cr0, Cb1, Cr1, ...
// dst points to the first 16-bit component, stride is in uint16_t elements (not bytes),
// width is the number of chroma samples per row (i.e. number of Cb values), height is rows.
void uv_fill_interleaved_u16(uint16_t *dst, int width, int height, int dstStride, uint16_t cb, uint16_t cr);

#endif /* hdr_interleave_h */
