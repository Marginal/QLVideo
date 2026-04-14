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

#endif /* hdr_interleave_h */
